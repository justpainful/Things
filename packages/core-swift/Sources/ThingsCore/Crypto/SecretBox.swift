import Foundation
import CryptoKit

/// AES-256-GCM envelope — **NORMATIVE**, defined by `spec/crypto.md` and pinned byte-for-byte
/// by `spec/vectors/crypto-envelope.json`. The TypeScript core produces identical bytes.
///
/// Used for every small sealed value: secret field values (`field.value_cipher`, and the same
/// bytes inside `attrs_json`) *and* wrapped key material (`dek_wrap_pin`, `dek_wrap_device`,
/// `object.enc_key_wrap`). One envelope, one parser.
///
///     offset  size  contents
///     0       4     magic "TENV"  (0x54 0x45 0x4e 0x56)
///     4       1     version, currently 0x01
///     5       1     algorithm, 0x01 = AES-256-GCM / 12-byte nonce / 16-byte tag
///     6       1     nonce length (12)
///     7       12    GCM nonce
///     19      n     ciphertext
///     19+n    16    GCM tag
///
/// **The 7-byte header is itself authenticated**: it is prepended to the caller's AAD before
/// being handed to GCM. Editing the version or algorithm byte therefore breaks the tag, so a
/// downgrade to a weaker algorithm cannot be forged by rewriting the header of a captured
/// envelope.
///
/// **AAD for a secret field = utf8(thing_id) ‖ utf8(field_id)**, plain concatenation of the two
/// canonical 36-character UUID strings. No separator is needed because both halves are fixed
/// width. This is what stops a ciphertext blob being transplanted into a different Thing to
/// trick the app into decrypting it somewhere it does not belong.
public enum SecretBox {

    /// ASCII "TENV". Note: **not** "TSEC" — an earlier draft of this file used that magic and
    /// no algorithm byte; the vectors are the contract and they say TENV.
    public static let magic: [UInt8] = Array("TENV".utf8)
    public static let version: UInt8 = 0x01
    /// The only algorithm defined at version 1.
    public static let algorithmAESGCM: UInt8 = 0x01
    public static let nonceByteCount = 12
    public static let tagByteCount = 16
    /// magic(4) ‖ version(1) ‖ algorithm(1) ‖ nonceLength(1)
    public static let headerByteCount = 7

    /// The literal header bytes. Also the prefix of the GCM additional data.
    public static var headerBytes: [UInt8] {
        magic + [version, algorithmAESGCM, UInt8(nonceByteCount)]
    }

    public static func additionalData(thingID: String, fieldID: String) -> Data {
        var data = Data(thingID.utf8)
        data.append(Data(fieldID.utf8))
        return data
    }

    // MARK: - Seal

    /// - Parameters:
    ///   - additionalData: the caller's AAD. The 7-byte header is prepended to it internally;
    ///     callers must not prepend it themselves.
    ///   - nonceBytes: **tests and conformance vectors only.** Production always uses a fresh
    ///     random nonce.
    public static func seal(_ plaintext: Data,
                            key: SymmetricKey,
                            additionalData: Data = Data(),
                            nonceBytes: [UInt8]? = nil) throws -> Data {
        do {
            let nonce: AES.GCM.Nonce
            if let nonceBytes {
                guard nonceBytes.count == nonceByteCount else {
                    throw ThingsError.cryptoFailure("nonce must be \(nonceByteCount) bytes")
                }
                nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
            } else {
                nonce = AES.GCM.Nonce()
            }
            let header = headerBytes
            var authenticating = Data(header)
            authenticating.append(additionalData)

            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: authenticating)
            var envelope = Data(header)
            envelope.append(contentsOf: Array(nonce))
            envelope.append(sealed.ciphertext)
            envelope.append(sealed.tag)
            return envelope
        } catch let error as ThingsError {
            throw error
        } catch {
            throw ThingsError.cryptoFailure(String(describing: error))
        }
    }

    public static func seal(_ plaintext: Data,
                            key: SymmetricKey,
                            thingID: String,
                            fieldID: String,
                            nonceBytes: [UInt8]? = nil) throws -> Data {
        try seal(plaintext,
                 key: key,
                 additionalData: additionalData(thingID: thingID, fieldID: fieldID),
                 nonceBytes: nonceBytes)
    }

    // MARK: - Open

    public static func open(_ envelope: Data,
                            key: SymmetricKey,
                            additionalData: Data = Data()) throws -> Data {
        let bytes = [UInt8](envelope)
        guard bytes.count >= headerByteCount + nonceByteCount + tagByteCount else {
            throw ThingsError.envelopeMalformed("too short (\(bytes.count) bytes)")
        }
        guard Array(bytes[0..<4]) == magic else {
            throw ThingsError.envelopeMalformed("bad magic")
        }
        guard bytes[4] == version else {
            throw ThingsError.envelopeMalformed("unsupported version \(bytes[4])")
        }
        guard bytes[5] == algorithmAESGCM else {
            throw ThingsError.envelopeMalformed("unsupported algorithm \(bytes[5])")
        }
        guard Int(bytes[6]) == nonceByteCount else {
            throw ThingsError.envelopeMalformed("bad nonce length \(bytes[6])")
        }

        let nonceBytes = Array(bytes[headerByteCount..<(headerByteCount + nonceByteCount)])
        let bodyStart = headerByteCount + nonceByteCount
        let tagStart = bytes.count - tagByteCount
        let ciphertext = Data(bytes[bodyStart..<tagStart])
        let tag = Data(bytes[tagStart...])

        // The header travels through GCM as authenticated data, exactly as it was written.
        var authenticating = Data(bytes[0..<headerByteCount])
        authenticating.append(additionalData)

        do {
            let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed, using: key, authenticating: authenticating)
        } catch {
            // Wrong key, tampered bytes, or — the case this design exists for — an envelope
            // lifted from a different thing_id/field_id.
            throw ThingsError.cryptoFailure("could not decrypt: \(error)")
        }
    }

    public static func open(_ envelope: Data,
                            key: SymmetricKey,
                            thingID: String,
                            fieldID: String) throws -> Data {
        try open(envelope,
                 key: key,
                 additionalData: additionalData(thingID: thingID, fieldID: fieldID))
    }

    // MARK: - String helpers

    public static func sealString(_ plaintext: String,
                                  key: SymmetricKey,
                                  thingID: String,
                                  fieldID: String) throws -> Data {
        try seal(Data(plaintext.utf8), key: key, thingID: thingID, fieldID: fieldID)
    }

    public static func openString(_ envelope: Data,
                                  key: SymmetricKey,
                                  thingID: String,
                                  fieldID: String) throws -> String {
        let data = try open(envelope, key: key, thingID: thingID, fieldID: fieldID)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ThingsError.envelopeMalformed("plaintext is not UTF-8")
        }
        return text
    }

    /// A cheap structural check used by the History view, which must show *that* a secret
    /// changed without being able to show what it changed to.
    public static func looksLikeEnvelope(_ data: Data) -> Bool {
        data.count >= headerByteCount + nonceByteCount + tagByteCount && Array(data.prefix(4)) == magic
    }
}
