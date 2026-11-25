import Foundation
import XlessCore

/// The `clang` on `PATH` during `prepare` only (docker/shims/prepare/clang; contract doc, "Env-only fixes" 5).
/// `pod install` runs `expo-modules-jsi`'s `create-stub-xcframework.sh`, which compiles an empty stub dylib with
/// `clang -x c - -dynamiclib -o …/.stub-binary -install_name @rpath/ExpoModulesJSI.framework/ExpoModulesJSI` and no
/// target: on a Mac that is a Mach-O dylib, on Linux the host clang fails to link an ELF executable. A compile with
/// Darwin-only flags and no target can only mean Darwin, so it gets the iOS device target, the SDK and the SDK's
/// linker; everything else runs unchanged (native gem and node-gyp builds compile for the host).
/// CocoaPods only inspects the stub (to classify the framework as dynamic); the build replaces it.
/// The Darwin compile uses the image's app Swift toolchain's clang (Ruling R10), host compiles the image's own.
public enum PrepareClangShim {
    /// The host compiler the shim runs.
    public static let clang = "/usr/bin/clang"
    /// The stub's deployment target: React Native 0.86's minimum (the stub is never shipped).
    static let stubTarget = "arm64-apple-ios16.4"

    /// True for the Darwin-only compile without a target that the shim retargets to iOS.
    static func retargets(_ args: [String]) -> Bool {
        let targeted = args.contains { $0 == "-target" || $0.hasPrefix("--target=") || $0 == "-arch" || $0 == "-isysroot" }
        let darwinOnly = args.contains { $0 == "-dynamiclib" || $0 == "-install_name" }
        return darwinOnly && !targeted
    }

    /// The compiler for `args`: the app Swift toolchain's clang for the retargeted Darwin compile, else the host's.
    public static func executable(_ args: [String], swift: SwiftToolchain?) -> String {
        guard retargets(args), let swift else { return clang }
        return swift.tool("clang")
    }

    /// The host clang's arguments for `args`.
    public static func arguments(_ args: [String], sdk: DarwinSDK) throws -> [String] {
        guard retargets(args) else { return args }
        return ["-target", stubTarget, "-isysroot", try sdk.sdkPath("iphoneos").path, "-fuse-ld=\(sdk.ld64.path)", "-mlinker-version=907"] + args
    }
}
