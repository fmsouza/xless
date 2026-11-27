import Foundation
import XlessCore

/// Everything `swbuild` needs on Linux to build an Xcode project (or a Swift package) for `iphoneos` with the Darwin SDK
/// bundle, beyond the PIF and the build request: build setting overrides, a toolset and the process environment
/// (docs/research/react-native-ios-contract.md, "Swift Build on Linux — spike G2" and "Gate G3/G4"). Shared by the
/// `xcodebuild` shim (Swift packages built inside a build phase) and the React Native build.
public struct SwiftBuildEnvironment: Sendable {
    public let sdk: DarwinSDK
    /// The image's shim directory (`XLESS_SHIM_DIR`): `xless-ld64` (the linker) and `swift-build/` (tools Swift Build
    /// must find before the toolchain's: `strip`, `embeddedBinaryValidationUtility`).
    public let shimDirectory: URL
    /// Headers Apple's clang finds in the toolchain's `usr/include` (Swift's `swift/bridging` and its module map), of
    /// the Xcode's Swift toolchain (`XcodeEnvironment.include`).
    public let toolchainInclude: URL
    /// The Swift toolchain that compiles (Ruling R10: the one the Xcode ships); nil: the `swift` on PATH.
    public let swift: SwiftToolchain?
    /// Swift Build's `swbuild` (`XcodeEnvironment.swbuild`); nil: the one on the build's PATH.
    public let swbuild: URL?

    public init(sdk: DarwinSDK, shimDirectory: URL, toolchainInclude: URL, swift: SwiftToolchain? = nil, swbuild: URL? = nil) {
        self.sdk = sdk
        self.shimDirectory = shimDirectory
        self.toolchainInclude = toolchainInclude
        self.swift = swift
        self.swbuild = swbuild
    }

    /// The Xcode's (`XcodeEnvironment`, with Swift Build) and the shims of this machine; refuses without either.
    public static func fromProcess(_ env: [String: String] = ProcessInfo.processInfo.environment, stage: Stage) throws -> SwiftBuildEnvironment {
        guard let shims = env["XLESS_SHIM_DIR"], !shims.isEmpty else {
            throw XlessError(stage, "the Xcode tool shims are not installed on this machine (XLESS_SHIM_DIR)",
                             fix: "build in Docker, where the xless image has them: xless setup --docker --xcode <path to Xcode's .xip>, then xless run --docker")
        }
        let xcode: XcodeEnvironment
        do { xcode = try XcodeEnvironment.current(env: env, needs: [.sdk, .swiftBuild]) } catch let problem as XcodeProblem {
            throw problem.stageError(stage)
        }
        guard let include = xcode.include else {
            throw XlessError(stage, "the Swift toolchain's include directory is not known (no Xcode pack, and XLESS_TOOLCHAIN_INCLUDE is not set)",
                             fix: "xless setup --xcode <path to Xcode's .app or .xip>")
        }
        return SwiftBuildEnvironment(sdk: DarwinSDK(bundle: xcode.sdkBundle), shimDirectory: URL(fileURLWithPath: shims), toolchainInclude: include,
                                     swift: try xcode.loadToolchain(stage: stage), swbuild: xcode.swbuild)
    }

    /// The Swift SDK toolset Swift Build reads (`SWIFT_SDK_TOOLSETS`): the SDK's own (`toolset-swb.json`: `llvm-lib`
    /// as librarian) with the linker replaced by `xless-ld64`, which links the archives the SDK's `ld64.lld -r`
    /// trampoline writes as the objects they stand for (`LinkerShim`). A toolset wins over command-line overrides
    /// (Swift Build applies it last), so the linker can only be set here. With a Swift toolchain other than the image's
    /// own (Ruling R10) the compilers are its `swiftc`, `clang` and `clang++` (`SWIFT_EXEC`, `CC`, `CPLUSPLUS`);
    /// `processEnvironment` also makes it the toolchain Swift Build runs everything else from (`swift-frontend`, the
    /// dependency scanner). The image's own Swift (the default chain's record) leaves them to the toolchain on PATH.
    public func toolset() -> Data {
        var fields: [String: JSON] = [
            "schemaVersion": .string("1.0"),
            "rootPath": .string(sdk.bundle.appendingPathComponent("toolset/bin").path),
            "linker": .object(["path": .string(shimDirectory.appendingPathComponent("xless-ld64").path)]),
            "librarian": .object(["path": .string("llvm-lib")]),
        ]
        if let swift, !swift.isEngine {
            fields["swiftCompiler"] = .object(["path": .string(swift.tool("swiftc"))])
            fields["cCompiler"] = .object(["path": .string(swift.tool("clang"))])
            fields["cxxCompiler"] = .object(["path": .string(swift.tool("clang++"))])
        }
        return Data(JSON.object(fields).serialized(pretty: true).utf8)
    }

    /// Build setting overrides (the request's command-line table). Each is needed on Linux only:
    /// - the G2 set: no Apple-only tools (`appintentsmetadataprocessor`, `tapi`, `bitcode_strip`), no signing (the
    ///   sign stage signs);
    /// - `-idirafter <toolchain include>`: Apple's clang searches the toolchain's `usr/include` after the SDK's, the
    ///   open-source one does not (C++ interop headers `#include <swift/bridging>`);
    /// - `AssumeResilientCxxTypes`: open-source Swift 6.4 diagnoses C++ types in public extensions of a
    ///   library-evolution module, which Xcode's Swift 6.4 accepts; the feature only turns that diagnostic off;
    /// - `SWIFT_LIBRARY_PATH`: the toolchain's Swift libraries for the platform (`libswiftCxx.a`, the back-deployment
    ///   `libswiftCompatibility*.a`), which Swift Build otherwise looks for next to the Linux `swiftc` (`/usr/lib/swift`);
    /// - `CLANG_WARN_DOCUMENTATION_COMMENTS = NO`: the toolchain's clang 21 crashes (SIGSEGV in
    ///   `ASTContext::getRawCommentForDeclNoCacheImpl`) on some Objective-C++ files with `-Wdocumentation`, which
    ///   Xcode's clang compiles; the setting only adds warnings.
    public func overrides(toolset: URL) -> [String: String] {
        let include = toolchainInclude.path
        // Ruling R10: the defaults Apple's clang has and the toolchain's lacks (`SwiftToolchain.clangFlags`).
        let clang = (swift?.clangFlags ?? []).map { " " + $0 }.joined()
        let swiftClang = (swift?.clangFlags ?? []).map { " -Xcc " + $0 }.joined()
        return [
            "SWIFT_SDK_TOOLSETS": toolset.path,
            "CODE_SIGNING_ALLOWED": "NO",
            "LM_SKIP_METADATA_EXTRACTION": "YES",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",
            "STRIP_BITCODE_FROM_COPIED_FILES": "NO",
            "SWIFT_STDLIB_TOOL_STRIP_BITCODE": "NO",
            "OTHER_CFLAGS": "$(inherited) -idirafter \(include)\(clang)",
            "OTHER_CPLUSPLUSFLAGS": "$(inherited) -idirafter \(include)\(clang)",
            "OTHER_SWIFT_FLAGS": "$(inherited) -Xcc -idirafter -Xcc \(include)\(swiftClang) -enable-experimental-feature AssumeResilientCxxTypes",
            "SWIFT_LIBRARY_PATH": sdk.toolchain.appendingPathComponent("usr/lib/swift").path + "/$(PLATFORM_NAME)",
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO",
        ]
    }

    /// Changes to `swbuild`'s environment (nil removes a variable). Script phases inherit it.
    /// - `SDKROOT` unset and `XCODE_EXTRA_PLATFORM_FOLDERS`: `swbuild` then sees the bundle's iOS platform (G2);
    /// - `PATH` gains the bundle's toolset, and the Swift toolchain before the image's own Swift (`SwiftToolchain.path`):
    ///   Swift Build takes its toolchain from the first `swift` on PATH (its Linux platform plugin), and build phases'
    ///   `clang`, `swiftc` and `xcrun swiftc --version` are that toolchain's;
    /// - `__XCODE_BUILT_PRODUCTS_DIR_PATHS`: directories Swift Build searches for tools before the toolchain's
    ///   (`/usr/bin` for the Linux toolchain at `/`, whose GNU `strip` cannot read Mach-O);
    /// - `TAR_OPTIONS`: GNU tar reads macOS-made tarballs as bsdtar does (no AppleDouble `._*` files, no warnings on
    ///   stderr), for build phases that extract them (Expo's precompiled-module switch).
    public func processEnvironment(path: String?) -> [String: String?] {
        [
            "SDKROOT": nil,
            "XCODE_EXTRA_PLATFORM_FOLDERS": sdk.bundle.appendingPathComponent("Developer/Platforms").path,
            "PATH": sdk.bundle.appendingPathComponent("toolset/bin").path + ":" + (swift?.path(path) ?? path ?? "/usr/bin:/bin"),
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": shimDirectory.appendingPathComponent("swift-build").path,
            "TAR_OPTIONS": "--warning=no-unknown-keyword --exclude=._*",
        ]
    }
}
