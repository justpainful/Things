import Foundation
import CryptoKit

/// scrypt parameters, stored beside the salt in `vault.json` so they can be raised later
/// without breaking an existing library.
///
/// **The serialised field names are wire format** — `spec/crypto.md` §6. They are the ones the
/// TypeScript core writes: `{"algorithm":"scrypt","N":65536,"r":8,"p":2,"dkLen":32}`. The Swift
/// property names stay idiomatic; only the JSON spelling is pinned. Key order is irrelevant to
/// a JSON parser, so this core emits its usual sorted-key canonical form.
public struct KDFParameters: Sendable, Equatable, Codable {

    public var algorithm: String
    /// scrypt N — cost. Must be a power of two. Serialised as `"N"`.
    public var n: Int
    /// scrypt r — block size. Serialised as `"r"`.
    public var r: Int
    /// scrypt p — parallelism. Serialised as `"p"`.
    public var p: Int
    /// Derived key length. Serialised as `"dkLen"`.
    public var keyByteCount: Int

    public init(algorithm: String = "scrypt", n: Int = 1 << 16, r: Int = 8, p: Int = 2, keyByteCount: Int = 32) {
        self.algorithm = algorithm
        self.n = n
        self.r = r
        self.p = p
        self.keyByteCount = keyByteCount
    }

    /// OWASP's scrypt recommendation, calibrated so the slowest device — the iPhone —
    /// stays near 0.3–0.5 s. Node's built-in scrypt takes the same three numbers, so both
    /// cores agree with no third-party dependency on either side.
    public static let recommended = KDFParameters()

    /// N = 2^14. **Test and Screenshot-Tour use only.** The full parameters take long
    /// enough that a UI test would spend most of its budget in the KDF.
    public static let fast = KDFParameters(n: 1 << 14, r: 8, p: 1)

    public var json: String {
        JSONValue.object([
            "algorithm": .string(algorithm),
            "N": .number(n),
            "r": .number(r),
            "p": .number(p),
            "dkLen": .number(keyByteCount)
        ]).canonicalJSON
    }

    /// Reads the normative spelling (`N`, `dkLen`). The lower-case `n` / `keyByteCount`
    /// spellings an earlier draft of this file wrote are still accepted on read, so a vault
    /// written by that draft keeps opening; nothing writes them any more.
    public static func parse(_ text: String?) -> KDFParameters {
        guard let text, let value = try? JSONValue.parse(text) else { return .recommended }
        return KDFParameters(
            algorithm: value["algorithm"]?.stringValue ?? "scrypt",
            n: value["N"]?.intValue ?? value["n"]?.intValue ?? KDFParameters.recommended.n,
            r: value["r"]?.intValue ?? KDFParameters.recommended.r,
            p: value["p"]?.intValue ?? KDFParameters.recommended.p,
            keyByteCount: value["dkLen"]?.intValue ?? value["keyByteCount"]?.intValue ?? 32
        )
    }
}

/// The DEK is a random 256-bit key that encrypts everything. It is **never derived from
/// the PIN** — it is *wrapped* by keys that are, twice and independently:
///
///   1. PIN path      — PIN → scrypt → KEK → unwrap. Always available; the recovery route.
///   2. Device path   — Secure Enclave P-256 → ECDH → HKDF → KEK₂ → unwrap. Convenience.
///
/// Either wrapper alone opens the DEK. That matters because `.biometryCurrentSet`
/// permanently invalidates the device key when the user re-enrols Face ID, and if that were
/// the only door the entire library would be gone.
public enum KeyHierarchy {

    public static let dekByteCount = 32
    public static let saltByteCount = 16

    /// Domain separators, so a key derived for one purpose can never be mistaken for
    /// another. **These exact strings are part of the on-disk format** — they are the AAD of
    /// the envelope that holds each wrapped key, and the TypeScript core writes the same
    /// bytes (`spec/crypto.md` §3). Colons, not dots; an earlier draft of this file used
    /// dotted names and the two cores could not open each other's wrapped DEK.
    public enum Context {
        public static let pinWrap = "things:dek-wrap:pin:v1"
        public static let deviceWrap = "things:dek-wrap:device:v1"
        public static let objectKeyWrap = "things:object-key:v1"
        public static let backup = "things:backup:v1"
        /// HKDF `info` for the device KEK (KEK₂).
        public static let deviceAgreement = "things:kek2:v1"
    }

    public static func generateDEK(clock: ThingsClock = SystemClock.shared) -> SymmetricKey {
        SymmetricKey(data: Data(clock.randomBytes(dekByteCount)))
    }

    public static func generateSalt(clock: ThingsClock = SystemClock.shared) -> Data {
        Data(clock.randomBytes(saltByteCount))
    }

    /// PIN → KEK. The PIN is normalised to UTF-8 bytes with no trimming: a leading zero is
    /// part of the PIN.
    public static func deriveKEK(pin: String, salt: Data, parameters: KDFParameters = .recommended) throws -> SymmetricKey {
        guard parameters.algorithm == "scrypt" else {
            throw ThingsError.keyDerivationFailed("unsupported KDF '\(parameters.algorithm)'")
        }
        let bytes = try ScryptKDF.derive(
            password: Data(pin.utf8),
            salt: salt,
            outputByteCount: parameters.keyByteCount,
            n: parameters.n,
            r: parameters.r,
            p: parameters.p
        )
        return SymmetricKey(data: Data(bytes))
    }

    /// Wraps a key in the standard `TENV` envelope (`SecretBox`), with the context string as
    /// the caller AAD — so a PIN-wrapped DEK cannot be presented as a device-wrapped one.
    ///
    /// The envelope is the same one secret fields use. An earlier draft of this file stored
    /// `AES.GCM.SealedBox.combined` instead (nonce ‖ ciphertext ‖ tag, no header), which the
    /// TypeScript core cannot parse: it is not the format in `spec/vectors/crypto-envelope.json`.
    public static func wrap(_ key: SymmetricKey, with wrappingKey: SymmetricKey, context: String) throws -> Data {
        let material = key.withUnsafeBytes { Data($0) }
        return try SecretBox.seal(material, key: wrappingKey, additionalData: Data(context.utf8))
    }

    public static func unwrap(_ wrapped: Data, with wrappingKey: SymmetricKey, context: String) throws -> SymmetricKey {
        do {
            let material = try SecretBox.open(wrapped, key: wrappingKey, additionalData: Data(context.utf8))
            return SymmetricKey(data: material)
        } catch {
            throw ThingsError.cryptoFailure("could not unwrap key: \(error)")
        }
    }

    /// Raw device secret → KEK₂, the rule pinned by `spec/vectors/crypto-envelope.json` →
    /// `deviceKek`: `HKDF-SHA256(ikm: device secret, salt: kdf salt, info: "things:kek2:v1")`.
    ///
    /// This is the Windows shape, where the device secret is 32 DPAPI-sealed bytes. iOS has no
    /// raw device secret to feed it — the Secure Enclave holds P-256 keys only — so on this
    /// platform `deriveKEK(fromSharedSecret:…)` below produces KEK₂ instead. Both are local to
    /// one device and never travel, so they do not have to agree byte for byte; the salt and
    /// the `info` string are unified anyway so there is one rule to reason about.
    public static func deriveDeviceKEK(deviceSecret: Data,
                                       salt: Data,
                                       info: String = Context.deviceAgreement) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: deviceSecret),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// ECDH shared secret → KEK₂. Used with the Secure Enclave key on device and with the
    /// software fallback key in the simulator.
    public static func deriveKEK(fromSharedSecret secret: SharedSecret, salt: Data, info: String = Context.deviceAgreement) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// The raw 64-hex-character key SQLCipher wants for `PRAGMA key = "x'…'"`.
    public static func sqlcipherRawKey(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Hex.encode(Array($0)) }
    }

    /// Escalating delay after a failed PIN attempt. Things deliberately never wipes: this
    /// is a local-only app with no cloud copy, so an auto-wipe turns a forgotten PIN into
    /// permanent data loss.
    public static func lockoutSeconds(afterFailedAttempts attempts: Int) -> Int {
        switch attempts {
        case ..<3: return 0
        case 3: return 1
        case 4: return 5
        case 5: return 30
        case 6: return 300
        default: return 900
        }
    }
}
