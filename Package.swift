// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "xless",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "xless", targets: ["xless"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.0.0"),
        .package(path: "ThirdParty/AssetKit"), // vendored, patched AssetKit; see ThirdParty/AssetKit/README.md
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"), // already pulled in by AssetKit
        .package(url: "https://github.com/attaswift/BigInt", from: "5.4.0"), // Apple ID sign-in: SRP's big-number arithmetic
    ],
    targets: [
        .target(name: "XlessCore", dependencies: ["CXlessProcess", .product(name: "Yams", package: "Yams")]),
        // The Docker images: their names and labels, the choice of one, and the derived images built from shipped Dockerfiles.
        .target(name: "XlessImages", dependencies: ["XlessCore", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "XlessSDK", dependencies: ["XlessCore", "XlessImages", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "XlessMachO"),
        .target(name: "XlessBuild", dependencies: ["XlessCore", "XlessMachO"]),
        .target(name: "XlessAssets", dependencies: [
            "XlessCore", "XlessMachO", "XlessIB",
            .product(name: "AssetKit", package: "AssetKit"),
            .product(name: "PNG", package: "swift-png"),
        ]),
        .target(name: "XlessIB", dependencies: ["XlessCore"]),
        .target(name: "XlessFinalize", dependencies: ["XlessCore", "XlessMachO"]),
        .target(name: "XlessASC", dependencies: [
            "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "XlessSign", dependencies: [
            "XlessCore", "XlessASC", "XlessMachO", "CXlessProcess",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .target(name: "XlessPackage", dependencies: ["XlessCore", "XlessMachO", "XlessSign", "XlessASC", .product(name: "Crypto", package: "swift-crypto")]),
        // Xcode workspace / project / scheme reader and Swift Build PIF writer (React Native / CocoaPods subset).
        .target(name: "XlessXcode", dependencies: ["XlessCore", "XlessMachO"]),
        .target(name: "XlessTauri", dependencies: [
            "XlessCore", "XlessMachO",
            .product(name: "Yams", package: "Yams"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // React Native / Expo iOS apps (`type: react-native` overlays): prepare (prebuild, CocoaPods) and the Swift Build build.
        .target(name: "XlessReactNative", dependencies: [
            "XlessCore", "XlessMachO", "XlessXcode", "XlessTauri", "XlessCargo",
            .product(name: "Yams", package: "Yams"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // Plain Cargo apps (`type: cargo` overlays): a Rust binary built for iOS and/or macOS and packaged without Xcode.
        .target(name: "XlessCargo", dependencies: [
            "XlessCore", "XlessMachO", "XlessTauri",
            .product(name: "Yams", package: "Yams"),
        ]),
        // C for what Swift cannot call: variadic prctl (SecretScope), explicit_bzero/memset_s (SecretBytes), and the kernel
        // keyring's add_key/keyctl syscalls (KernelKeyring) without libkeyutils, so the static musl build keeps working.
        // libbsm (macOS): audit tokens, the identity of a process at the other end of a socket.
        .target(name: "CXlessProcess", linkerSettings: [.linkedLibrary("bsm", .when(platforms: [.macOS]))]),
        // FIDO security keys spoken to directly (CBOR, CTAPHID, CTAP2 and U2F, over Linux /dev/hidraw or macOS's IOKit),
        // with no libfido2 so the static musl build keeps working: the Apple ID sign-in's security-key second factor.
        .target(name: "XlessFIDO", dependencies: [
            "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ], linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]),
        // Apple ID sign-in (SRP, 2FA) and Xcode .xip downloads from developer.apple.com (`xless xcode download`).
        .target(name: "XlessAppleID", dependencies: [
            "CXlessProcess",
            "XlessCore",
            "XlessFIDO",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "BigInt", package: "BigInt"),
        ]),
        // The encrypted secret store (`xless secrets`) and `Secrets`' fallback to it.
        .target(name: "XlessVault", dependencies: [
            "XlessCore", "CXlessProcess",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        // The xless agent (docs/security.md#the-xless-agent): the opt-in process that holds the store's data key and an
        // Apple ID session in memory for `xless unlock`, `--remember` and `--keep`, and its client.
        .target(name: "XlessAgent", dependencies: [
            "XlessCore", "CXlessProcess",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // The App Store listing as an `appstore/` directory (docs/appstore-manifest.md): its model, `xless store pull`
        // (App Store Connect → files) and `validate` (offline checks); `store push` and `provision` build on it. App
        // Privacy goes through the Apple ID web session (XlessAppleID's `ASCWebPrivacy`).
        .target(name: "XlessStore", dependencies: [
            "XlessCore", "XlessASC", "XlessAppleID",
            .product(name: "Yams", package: "Yams"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // `xless run`: a project's build, sign and upload as processes of their own (containers, or natively), so that the app's
        // build code never runs next to a secret.
        .target(name: "XlessRun", dependencies: [
            "XlessCore", "XlessImages", "CXlessProcess",
            .product(name: "Yams", package: "Yams"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .executableTarget(name: "xless", dependencies: [
            "XlessCore", "XlessTauri", "XlessSDK", "XlessBuild", "XlessAssets", "XlessFinalize", "XlessSign", "XlessASC", "XlessPackage", "XlessIB",
            "XlessXcode", "XlessReactNative", "XlessCargo", "XlessAppleID", "XlessVault", "XlessAgent", "XlessStore", "XlessRun", "XlessImages", "CXlessProcess",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-adhoc_codesign"], .when(platforms: [.macOS]))]), // the agent knows it by its signature; for Intel the linker makes none by itself
        // Research tool: compares the storyboard compiler with ibtool outputs (scripts/ib-corpus/differential.py).
        // Not a product: `--product xless` (image builds) skips it; only `swift run IBDifferential` builds it.
        .executableTarget(name: "IBDifferential", dependencies: ["XlessIB", "XlessCore"]),
        .testTarget(name: "XlessCoreTests", dependencies: ["XlessCore", "CXlessProcess"]),
        .testTarget(name: "XlessImagesTests", dependencies: ["XlessImages", "XlessCore"]),
        .testTarget(name: "XlessSDKTests", dependencies: ["XlessSDK", "XlessImages", "XlessCore", .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "XlessBuildTests", dependencies: ["XlessBuild", "XlessCore", "XlessMachO"]),
        .testTarget(name: "XlessAssetsTests", dependencies: [
            "XlessAssets", "XlessCore", "XlessMachO",
            .product(name: "PNG", package: "swift-png"),
            .product(name: "Crypto", package: "swift-crypto"),
        ], exclude: ["Fixtures"]),
        .testTarget(name: "XlessFinalizeTests", dependencies: ["XlessFinalize", "XlessCore", "XlessMachO"]),
        .testTarget(name: "XlessASCTests", dependencies: [
            "XlessASC", "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessSignTests", dependencies: [
            "XlessSign", "XlessASC", "XlessCore", "XlessMachO",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessPackageTests", dependencies: ["XlessPackage", "XlessCore", "XlessMachO", .product(name: "Crypto", package: "swift-crypto")], exclude: ["Fixtures"]),
        .testTarget(name: "XlessIBTests", dependencies: ["XlessIB", "XlessCore"]),
        .testTarget(name: "XlessTauriTests", dependencies: ["XlessTauri", "XlessCore", "XlessMachO", .product(name: "Crypto", package: "swift-crypto")], exclude: ["Fixtures"]),
        .testTarget(name: "XlessMachOTests", dependencies: ["XlessMachO"]),
        .testTarget(name: "XlessReactNativeTests", dependencies: ["XlessReactNative", "XlessXcode", "XlessCore", "XlessTauri", "XlessASC"]),
        .testTarget(name: "XlessCargoTests", dependencies: ["XlessCargo", "XlessCore", "XlessTauri", "XlessMachO", "XlessReactNative"]),
        .testTarget(name: "XlessFIDOTests", dependencies: [
            "XlessFIDO", "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessAppleIDTests", dependencies: [
            "XlessAppleID", "XlessCore", "XlessFIDO",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "BigInt", package: "BigInt"),
        ]),
        .testTarget(name: "XlessVaultTests", dependencies: [
            "XlessVault", "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessAgentTests", dependencies: [
            "XlessAgent", "XlessCore", "CXlessProcess",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessStoreTests", dependencies: [
            "XlessStore", "XlessASC", "XlessCore", "XlessAppleID",
            .product(name: "Yams", package: "Yams"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // The CLI's command tree (ArgumentParser's help dump): no option or argument named like a secret.
        .testTarget(name: "XlessCLITests", dependencies: ["xless", "XlessCore", "XlessASC", "XlessStore", "XlessAppleID", "XlessVault", "XlessAgent", "XlessSign", "XlessRun", .product(name: "Crypto", package: "swift-crypto"), .product(name: "X509", package: "swift-certificates"), .product(name: "SwiftASN1", package: "swift-asn1"), .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "XlessRunTests", dependencies: ["XlessRun", "XlessImages", "XlessCore"]),
        .testTarget(name: "XlessXcodeTests", dependencies: ["XlessXcode", "XlessCore", "XlessTauri", "XlessMachO"], exclude: ["Fixtures"]),
    ]
)

// What Windows builds so far: the libraries that the account commands use, without the files below, which need what Windows does
// not have (or not yet). Tests/windows/sources.txt says of every file of these targets which of the two it is (WindowsSourcesTests).
// `swift build -Xmanifest -DXLESS_WINDOWS_TARGETS` builds the same targets and files on another system.
#if os(Windows) || XLESS_WINDOWS_TARGETS
let windowsTargets: Set<String> = [
    "CXlessProcess", "XlessCore", "XlessASC", "XlessSign", "XlessFIDO", "XlessAppleID", "XlessVault", "XlessStore",
    "XlessCoreTests", "XlessASCTests", "XlessSignTests", "XlessFIDOTests", "XlessAppleIDTests", "XlessVaultTests", "XlessStoreTests",
]
let notOnWindows: [String: [String]] = [
    "XlessCore": [
        "BuildSDKCheck.swift", "BuiltTree.swift", "ChildProcess.swift", "DittoShim.swift", "ExecutableFile.swift",
        "MemoryFileSystem.swift", "NativeLayout.swift", "PlistBuddyShim.swift", "Shell.swift", "SwiftToolchain.swift", "XcrunShim.swift",
        "XlessShare.swift", "AppleSignature.swift", "InstalledXcode.swift", "NativeTools.swift", "TrustedPath.swift",
        "PackageResolved.swift",
    ],
    "XlessSign": ["PrivateFiles.swift", "RCodesign.swift", "SignStage.swift"],
    "XlessVault": ["CredentialHelper.swift", "VaultMaterialize.swift"],
    "XlessCoreTests": [
        "BuildSDKCheckTests.swift", "BuiltTreeTests.swift", "ChildProcessTests.swift", "DittoShimTests.swift", "ExecutableFileTests.swift", "NativeLayoutTests.swift", "PlainFileTests.swift", "PlistBuddyShimTests.swift",
        "SecretScrubTests.swift", "ShellTests.swift", "SwiftToolchainTests.swift", "XcrunShimTests.swift", "XlessShareTests.swift",
        "AppleSignatureTests.swift", "InstalledXcodeTests.swift", "NativeToolsTests.swift", "TrustedPathTests.swift",
        "PackageResolvedTests.swift",
    ],
    "XlessASCTests": ["PathOwnersTests.swift", "StreamingTransportTests.swift"],
    "XlessAppleIDTests": ["URLSessionAppleTransportTests.swift"],
    "XlessSignTests": ["MultiBundleSignTests.swift", "NestedSigningTests.swift", "PrivateFilesTests.swift", "RCodesignTests.swift", "SignStageTests.swift"],
    "XlessVaultTests": ["HelperSecretStoreTests.swift", "VaultMaterializeTests.swift"],
]
package.products = []
package.targets.removeAll { !windowsTargets.contains($0.name) }
for target in package.targets {
    target.exclude += notOnWindows[target.name] ?? []
    target.dependencies.removeAll { if case .byNameItem(let name, _) = $0 { name.hasPrefix("Xless") && !windowsTargets.contains(name) } else { false } }
    #if os(Windows)
    target.dependencies = target.dependencies.map { if case .byNameItem("CXlessProcess", _) = $0 { "CXlessWindows" } else { $0 } }
    #else
    target.swiftSettings = (target.swiftSettings ?? []) + [.define("XLESS_WINDOWS_TARGETS")]
    #endif
}
#if os(Windows)
package.targets.removeAll { $0.name == "CXlessProcess" }
for target in package.targets where ["XlessCoreTests", "XlessVaultTests", "XlessSignTests"].contains(target.name) {
    target.dependencies += ["CXlessWindowsTestSupport"]
}
package.targets += [
    .target(name: "CXlessWindows", linkerSettings: ["Advapi32", "Ole32", "Shell32"].map { .linkedLibrary($0) }),
    .target(name: "CXlessWindowsTestSupport", path: "Tests/CXlessWindowsTestSupport", linkerSettings: [.linkedLibrary("Advapi32")]),
    // What Tests/windows/no-dump.test.ps1 lets crash.
    .executableTarget(name: "XlessWindowsProbe", dependencies: ["XlessCore", "CXlessWindowsTestSupport"], path: "Tests/XlessWindowsProbe"),
]
#endif
#endif
