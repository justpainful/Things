import Foundation
import Crypto
import _CryptoExtras

/// **This is the only file in the project that imports `_CryptoExtras`.**
///
/// It exists as a one-function firewall around `KDF.Scrypt`. Nobody on this project can
/// compile Swift locally, so if that symbol's argument labels differ from what is written
/// here, the fix must be one edit in one place rather than a hunt.
///
/// Why scrypt at all: CryptoKit ships exactly one KDF, HKDF, which is not password-based.
/// swift-crypto's CryptoExtras adds `KDF.Insecure.PBKDF2` and `KDF.Scrypt`. Scrypt is the
/// only *memory-hard* option Apple ships, and memory-hardness is precisely the property
/// that blunts GPU parallelism against a six-digit PIN.
///
/// Note the namespace: PBKDF2 lives under `KDF.Insecure`, **scrypt does not** — it is
/// `KDF.Scrypt`, declared in `Sources/CryptoExtras/Key Derivation/Scrypt/Scrypt.swift`.
///
/// The result is returned as raw bytes rather than a `SymmetricKey` so that the rest of the
/// package can use CryptoKit's `SymmetricKey` without ever having to reason about whether
/// swift-crypto's `Crypto.SymmetricKey` is the same type on Darwin.
enum ScryptKDF {

    static func derive(password: Data,
                       salt: Data,
                       outputByteCount: Int,
                       n: Int,
                       r: Int,
                       p: Int) throws -> [UInt8] {
        do {
            let derived = try KDF.Scrypt.deriveKey(
                from: password,
                salt: salt,
                outputByteCount: outputByteCount,
                rounds: n,
                blockSize: r,
                parallelism: p
            )
            return derived.withUnsafeBytes { Array($0) }
        } catch {
            throw ThingsError.keyDerivationFailed(String(describing: error))
        }
    }
}
