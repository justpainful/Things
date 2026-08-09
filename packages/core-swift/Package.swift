// swift-tools-version: 6.1
//
// ThingsCore — the Swift half of the Things core.
//
// Notes for whoever touches this next:
//  * GRDB comes from Zetetic's managed SQLCipher fork (SQLCipher already wired in).
//    Pinned exactly, because a silent minor bump on a machine that cannot compile
//    locally is a 10-minute CI round trip to discover.
//  * swift-crypto is here for ONE symbol: `KDF.Scrypt`, from `_CryptoExtras`. Note the
//    namespace — PBKDF2 is `KDF.Insecure.PBKDF2`, but scrypt is NOT under `Insecure`.
//    CryptoKit ships no memory-hard KDF. Everything else (AES-GCM, HKDF, SHA-256, P-256,
//    Secure Enclave) is CryptoKit.
//  * Swift 5 language mode on purpose. The code is written Sendable-clean, but the
//    first compile of this package happens on a CI runner with no way to iterate,
//    and Swift 6 mode turns concurrency nits into hard errors.

import PackageDescription

let package = Package(
    name: "ThingsCore",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "ThingsCore", targets: ["ThingsCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1")
    ],
    targets: [
        .target(
            name: "ThingsCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                // ONLY _CryptoExtras. Do NOT add the `Crypto` product back.
                //
                // On Apple platforms swift-crypto's `Crypto` is just a re-export of CryptoKit,
                // so it adds no API — but declaring it as a package PRODUCT made Xcode expect a
                // `Crypto_…_PackageProduct.framework` that it never built, and the link step
                // died with "no such file or directory". Sources import CryptoKit directly;
                // `_CryptoExtras` links its own copy of the Crypto target internally.
                .product(name: "_CryptoExtras", package: "swift-crypto")
            ],
            // The whole directory, copied verbatim, so it lands in the bundle as
            // `Resources/` and can be looked up with an explicit `subdirectory:`.
            // Copying individual *files* flattens them to the bundle root, which is a
            // difference nobody here can discover without a CI round trip.
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ThingsCoreTests",
            dependencies: ["ThingsCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
