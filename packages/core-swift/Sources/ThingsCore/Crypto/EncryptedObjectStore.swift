import Foundation
import CryptoKit

/// Content-addressed, encrypted, deduplicated file storage.
///
/// The hash is of the **plaintext** bytes, so dedupe survives even though every object gets
/// its own random key: "this file is already in Things" is a primary-key hit.
///
/// On disk: `objects/<hash[0:2]>/<hash[2:4]>/<hash>` — the fan-out also keeps Windows
/// directories under control at scale.
///
/// File layout — **NORMATIVE**, `spec/crypto.md` §5, pinned by
/// `spec/vectors/crypto-envelope.json` → `objectFrames`:
///
///     offset  size  contents
///     0       4     magic "TOBJ"
///     4       1     version 0x01
///     5       1     algorithm 0x01 = AES-256-GCM
///     6       4     frame size, big endian (1 MiB — the *plaintext* frame size)
///     10      8     nonce prefix
///     18      …     frames
///
///     each frame: 4-byte big-endian length of (ciphertext ‖ 16-byte tag), then those bytes
///
/// Frames exist so video can seek without decrypting the whole file.
///
///   * nonce for frame *i* = `noncePrefix (8 bytes) ‖ UInt32(i) big endian` — unique because
///     the prefix is random per object and the object key is used for nothing else.
///   * AAD for frame *i* = `UInt32(i) big endian ‖ isLastFrame (1 byte)`. The index stops
///     frames being reordered; the last-frame flag stops a truncation attack, which would
///     otherwise yield a shorter but perfectly valid-looking file.
///
/// A zero-byte object still gets exactly one (empty, last) frame, so `load` always has
/// something to authenticate instead of trusting an empty file.
public struct EncryptedObjectStore: Sendable {

    public static let magic: [UInt8] = Array("TOBJ".utf8)
    public static let version: UInt8 = 0x01
    /// The only algorithm defined at version 1.
    public static let algorithmAESGCM: UInt8 = 0x01
    public static let frameByteCount = 1 << 20          // 1 MiB of plaintext per frame
    public static let tagByteCount = 16
    public static let noncePrefixByteCount = 8
    /// magic(4) ‖ version(1) ‖ algorithm(1) ‖ frameSize(4) ‖ noncePrefix(8)
    public static let headerByteCount = 18
    /// Byte offset of the big-endian frame size inside the header.
    public static let frameSizeOffset = 6
    /// Byte offset of the nonce prefix inside the header.
    public static let noncePrefixOffset = 10
    /// Length prefix in front of every frame.
    public static let frameLengthByteCount = 4

    public struct Receipt: Sendable, Equatable {
        public var hash: String
        public var byteSize: Int64
        /// Per-object key wrapped by the DEK. Goes into `object.enc_key_wrap`.
        public var encKeyWrap: Data
        /// The 8-byte nonce prefix. Goes into `object.enc_nonce`.
        public var encNonce: Data
        public var isNewlyStored: Bool
    }

    public let rootDirectory: URL
    private let dek: SymmetricKey
    private let clock: ThingsClock

    public init(rootDirectory: URL, dek: SymmetricKey, clock: ThingsClock = SystemClock.shared) {
        self.rootDirectory = rootDirectory
        self.dek = dek
        self.clock = clock
    }

    // MARK: - Paths

    public static func sha256Hex(_ data: Data) -> String {
        Hex.encode(Array(SHA256.hash(data: data)))
    }

    public func directory(for hash: String) -> URL {
        let characters = Array(hash)
        guard characters.count >= 4 else { return rootDirectory }
        return rootDirectory
            .appendingPathComponent(String(characters[0..<2]), isDirectory: true)
            .appendingPathComponent(String(characters[2..<4]), isDirectory: true)
    }

    public func url(for hash: String) -> URL {
        directory(for: hash).appendingPathComponent(hash, isDirectory: false)
    }

    public func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    // MARK: - Store

    /// - Parameter replacingExisting: pass `true` when the caller has already established
    ///   that no `object` row owns the bytes on disk (an orphan left by a crash). Otherwise
    ///   an existing file short-circuits and the caller is expected to keep using the key
    ///   material already recorded in its `object` row.
    @discardableResult
    public func store(_ plaintext: Data, replacingExisting: Bool = false) throws -> Receipt {
        let hash = EncryptedObjectStore.sha256Hex(plaintext)
        let destination = url(for: hash)

        let objectKey = SymmetricKey(data: Data(clock.randomBytes(32)))
        let noncePrefix = Data(clock.randomBytes(EncryptedObjectStore.noncePrefixByteCount))
        let keyWrap = try KeyHierarchy.wrap(objectKey, with: dek, context: KeyHierarchy.Context.objectKeyWrap)

        if FileManager.default.fileExists(atPath: destination.path) {
            if replacingExisting {
                try FileManager.default.removeItem(at: destination)
            } else {
                // Already stored. Bytes are identical by construction, so the existing key
                // and nonce stay authoritative — the caller keeps the row it already has.
                return Receipt(hash: hash,
                               byteSize: Int64(plaintext.count),
                               encKeyWrap: Data(),
                               encNonce: Data(),
                               isNewlyStored: false)
            }
        }

        let out = try EncryptedObjectStore.encode(plaintext, key: objectKey, noncePrefix: noncePrefix)

        try FileManager.default.createDirectory(at: directory(for: hash), withIntermediateDirectories: true)
        try out.write(to: destination, options: .atomic)

        return Receipt(hash: hash,
                       byteSize: Int64(plaintext.count),
                       encKeyWrap: keyWrap,
                       encNonce: noncePrefix,
                       isNewlyStored: true)
    }

    // MARK: - Load

    public func load(hash: String, encKeyWrap: Data) throws -> Data {
        let source = url(for: hash)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThingsError.objectNotFound(hash)
        }
        let container = try Data(contentsOf: source)
        let objectKey = try KeyHierarchy.unwrap(encKeyWrap, with: dek, context: KeyHierarchy.Context.objectKeyWrap)
        return try EncryptedObjectStore.decode(container, hash: hash, objectKey: objectKey)
    }

    /// Decrypts a single frame — the seek path for video.
    public func loadFrame(hash: String, encKeyWrap: Data, frameIndex: Int) throws -> Data {
        let source = url(for: hash)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThingsError.objectNotFound(hash)
        }
        let container = try Data(contentsOf: source)
        let objectKey = try KeyHierarchy.unwrap(encKeyWrap, with: dek, context: KeyHierarchy.Context.objectKeyWrap)
        let header = try EncryptedObjectStore.parseHeader(container, hash: hash)
        let bounds = try EncryptedObjectStore.frameBounds(container, hash: hash)
        guard frameIndex >= 0, frameIndex < bounds.count else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "frame \(frameIndex) is past the end")
        }
        let frame = bounds[frameIndex]
        return try EncryptedObjectStore.openFrame(EncryptedObjectStore.slice(container,
                                                                            offset: frame.offset,
                                                                            length: frame.length),
                                                  key: objectKey,
                                                  noncePrefix: header.noncePrefix,
                                                  frameIndex: frameIndex,
                                                  isLast: frameIndex == bounds.count - 1,
                                                  hash: hash)
    }

    /// Decrypts only the plaintext range `[offset, offset + length)` — the property framing
    /// exists for. Touches the frames that range falls in, not the whole file.
    public func loadRange(hash: String, encKeyWrap: Data, offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "negative range")
        }
        let source = url(for: hash)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThingsError.objectNotFound(hash)
        }
        let container = try Data(contentsOf: source)
        let objectKey = try KeyHierarchy.unwrap(encKeyWrap, with: dek, context: KeyHierarchy.Context.objectKeyWrap)
        let header = try EncryptedObjectStore.parseHeader(container, hash: hash)
        let bounds = try EncryptedObjectStore.frameBounds(container, hash: hash)
        guard length > 0 else { return Data() }

        let first = offset / header.frameSize
        let last = min(bounds.count - 1, (offset + length - 1) / header.frameSize)
        guard first < bounds.count else { return Data() }

        var joined = Data()
        for index in first...last {
            let frame = bounds[index]
            joined.append(try EncryptedObjectStore.openFrame(
                EncryptedObjectStore.slice(container, offset: frame.offset, length: frame.length),
                key: objectKey,
                noncePrefix: header.noncePrefix,
                frameIndex: index,
                isLast: index == bounds.count - 1,
                hash: hash))
        }
        let localStart = offset - first * header.frameSize
        guard localStart < joined.count else { return Data() }
        let localEnd = min(joined.count, localStart + length)
        return EncryptedObjectStore.slice(joined, offset: localStart, length: localEnd - localStart)
    }

    public func delete(hash: String) throws {
        let target = url(for: hash)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: - Framing

    struct Header {
        var frameSize: Int
        var noncePrefix: Data
    }

    /// Where each frame's sealed bytes (ciphertext ‖ tag) live, excluding its length prefix.
    struct FrameBound {
        var offset: Int
        var length: Int
    }

    /// Slices `length` bytes starting `offset` bytes into `container`, counted from the
    /// container's own start. `Data` slices keep the parent's indices, so never index a
    /// `Data` with a bare integer offset.
    static func slice(_ container: Data, offset: Int, length: Int) -> Data {
        let start = container.startIndex + offset
        return container.subdata(in: start..<(start + length))
    }

    static func headerBytes(noncePrefix: Data, frameSize: Int = frameByteCount) -> Data {
        var header = Data()
        header.append(contentsOf: magic)
        header.append(version)
        header.append(algorithmAESGCM)
        header.append(contentsOf: bigEndian(UInt32(frameSize)))
        header.append(noncePrefix)
        return header
    }

    /// The whole-file encoder. Split out from `store` so the conformance vectors can drive it
    /// with a fixed key and nonce prefix.
    static func encode(_ plaintext: Data,
                       key: SymmetricKey,
                       noncePrefix: Data,
                       frameSize: Int = frameByteCount) throws -> Data {
        guard noncePrefix.count == noncePrefixByteCount else {
            throw ThingsError.cryptoFailure("nonce prefix must be \(noncePrefixByteCount) bytes")
        }
        guard frameSize > 0 else {
            throw ThingsError.cryptoFailure("frame size must be positive")
        }

        var out = headerBytes(noncePrefix: noncePrefix, frameSize: frameSize)

        // max(1, …): a zero-byte object still gets one empty, last frame.
        let frameCount = max(1, (plaintext.count + frameSize - 1) / frameSize)
        for index in 0..<frameCount {
            let start = index * frameSize
            let end = min(start + frameSize, plaintext.count)
            let framePlaintext = start < end ? slice(plaintext, offset: start, length: end - start) : Data()
            let nonce = try EncryptedObjectStore.nonce(prefix: noncePrefix, frameIndex: index)
            let sealed = try AES.GCM.seal(framePlaintext,
                                          using: key,
                                          nonce: nonce,
                                          authenticating: frameAdditionalData(frameIndex: index,
                                                                              isLast: index == frameCount - 1))
            var frame = Data(sealed.ciphertext)
            frame.append(sealed.tag)
            out.append(contentsOf: bigEndian(UInt32(frame.count)))
            out.append(frame)
        }
        return out
    }

    static func parseHeader(_ container: Data, hash: String) throws -> Header {
        guard container.count >= headerByteCount else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "shorter than its header")
        }
        let bytes = [UInt8](container.prefix(headerByteCount))
        guard Array(bytes[0..<4]) == magic else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "bad magic")
        }
        guard bytes[4] == version else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "unsupported version \(bytes[4])")
        }
        guard bytes[5] == algorithmAESGCM else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "unsupported algorithm \(bytes[5])")
        }
        var frameSize: UInt32 = 0
        for index in frameSizeOffset..<(frameSizeOffset + 4) {
            frameSize = frameSize << 8 | UInt32(bytes[index])
        }
        guard frameSize > 0 else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "zero frame size")
        }
        let noncePrefix = Data(bytes[noncePrefixOffset..<(noncePrefixOffset + noncePrefixByteCount)])
        return Header(frameSize: Int(frameSize), noncePrefix: noncePrefix)
    }

    /// Walks the length prefixes once. This is the index that makes seeking cheap — and the
    /// only way to know which frame is the last one, which the AAD binds.
    static func frameBounds(_ container: Data, hash: String) throws -> [FrameBound] {
        _ = try parseHeader(container, hash: hash)
        let bytes = [UInt8](container)
        var bounds: [FrameBound] = []
        var offset = headerByteCount
        while offset < bytes.count {
            guard offset + frameLengthByteCount <= bytes.count else {
                throw ThingsError.objectCorrupt(hash: hash, reason: "truncated frame length")
            }
            var length: UInt32 = 0
            for index in offset..<(offset + frameLengthByteCount) {
                length = length << 8 | UInt32(bytes[index])
            }
            let start = offset + frameLengthByteCount
            let end = start + Int(length)
            guard end <= bytes.count else {
                throw ThingsError.objectCorrupt(hash: hash, reason: "truncated frame \(bounds.count)")
            }
            bounds.append(FrameBound(offset: start, length: Int(length)))
            offset = end
        }
        guard !bounds.isEmpty else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "no frames")
        }
        return bounds
    }

    static func decode(_ container: Data, hash: String, objectKey: SymmetricKey) throws -> Data {
        let header = try parseHeader(container, hash: hash)
        let bounds = try frameBounds(container, hash: hash)
        var plaintext = Data()
        for (index, frame) in bounds.enumerated() {
            plaintext.append(try openFrame(slice(container, offset: frame.offset, length: frame.length),
                                           key: objectKey,
                                           noncePrefix: header.noncePrefix,
                                           frameIndex: index,
                                           isLast: index == bounds.count - 1,
                                           hash: hash))
        }
        guard sha256Hex(plaintext) == hash else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "content hash does not match its name")
        }
        return plaintext
    }

    static func openFrame(_ sealedFrame: Data,
                          key: SymmetricKey,
                          noncePrefix: Data,
                          frameIndex: Int,
                          isLast: Bool,
                          hash: String) throws -> Data {
        guard sealedFrame.count >= tagByteCount else {
            throw ThingsError.objectCorrupt(hash: hash, reason: "truncated frame \(frameIndex)")
        }
        let ciphertext = sealedFrame.prefix(sealedFrame.count - tagByteCount)
        let tag = sealedFrame.suffix(tagByteCount)
        do {
            let nonce = try EncryptedObjectStore.nonce(prefix: noncePrefix, frameIndex: frameIndex)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed,
                                    using: key,
                                    authenticating: frameAdditionalData(frameIndex: frameIndex, isLast: isLast))
        } catch {
            throw ThingsError.objectCorrupt(hash: hash, reason: "frame \(frameIndex) failed authentication")
        }
    }

    /// `noncePrefix (8 bytes) ‖ UInt32(frameIndex) big endian` = 12 bytes.
    static func nonce(prefix: Data, frameIndex: Int) throws -> AES.GCM.Nonce {
        guard prefix.count == noncePrefixByteCount else {
            throw ThingsError.cryptoFailure("nonce prefix must be \(noncePrefixByteCount) bytes")
        }
        guard frameIndex >= 0, frameIndex <= Int(UInt32.max) else {
            throw ThingsError.cryptoFailure("frame index out of range")
        }
        var bytes = [UInt8](prefix)
        bytes.append(contentsOf: bigEndian(UInt32(frameIndex)))
        return try AES.GCM.Nonce(data: Data(bytes))
    }

    /// `UInt32(frameIndex) big endian ‖ isLastFrame (1 byte)` = 5 bytes.
    static func frameAdditionalData(frameIndex: Int, isLast: Bool) -> Data {
        var bytes = bigEndian(UInt32(truncatingIfNeeded: frameIndex))
        bytes.append(isLast ? 1 : 0)
        return Data(bytes)
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24),
         UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }
}
