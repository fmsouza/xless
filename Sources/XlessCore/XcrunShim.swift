import Foundation

/// Answers the `xcrun` calls that cargo build scripts make (cc crate, etc.) and that React Native / CocoaPods build
/// phases make (`xcrun otool -LX …`, `xcrun swiftc --version`, `xcrun --find actool`, `xcrun actool …`) on Linux.
/// Anything else is refused loudly.
public enum XcrunShim {
    /// What a call resolves to: text to print, or a Linux tool to run in place of the Darwin one.
    public enum Action: Equatable {
        case output(String)
        case exec(path: String, args: [String])
    }

    public struct Unsupported: Error, CustomStringConvertible {
        public let argv: [String]
        public var description: String { "xcrun shim: unsupported call: xcrun \(argv.joined(separator: " "))" }
    }

    /// Darwin tool name → Linux executable (resolved through `which`). `ld` maps to the SDK's ld64.lld.
    static let toolMap = ["clang": "clang", "clang++": "clang++", "cc": "clang", "c++": "clang++",
                          "nm": "llvm-nm", "ar": "llvm-ar", "ranlib": "llvm-ranlib", "libtool": "llvm-libtool-darwin",
                          "lipo": "llvm-lipo", "strip": "llvm-strip", "otool": "llvm-otool", "swift": "swift", "swiftc": "swiftc"]

    /// Xcode tools that xcrun finds and runs from the image's shim directory (`XLESS_SHIM_DIR`), not through PATH:
    /// `actool`. CocoaPods' `[CP] Copy Pods Resources` phase (`copy_resources_script.rb`) probes it with
    /// `xcrun --find actool` inside a `[ … ]` test, where a failure is not an error, and compiles the pods' asset
    /// catalogs with `xcrun actool …`: a refused probe silently skips that compile. The actool shim checks its arguments.
    static let shimTools: Set<String> = ["actool"]

    /// The output of a query call (`--show-sdk-path`, `--find`, …); a tool invocation is refused here.
    /// `shim` resolves a `shimTools` name to its shim in the image's shim directory (nil: not installed).
    public static func run(_ args: [String], sdk: DarwinSDK, which: (String) -> String?, shim: (String) -> String? = { _ in nil }) throws -> String {
        guard case .output(let text) = try resolve(args, sdk: sdk, which: which, shim: shim) else { throw Unsupported(argv: args) }
        return text
    }

    /// Tools `xcrun <tool> args…` may run: LLVM's Mach-O-aware binutils, whose output does not depend on the SDK or
    /// host (CocoaPods' embed-frameworks script runs `xcrun otool -LX` and calls `lipo` by name, docker/shims).
    /// Compilers are not run through xcrun: without the SDK's target and sysroot they would silently build for the
    /// Linux host; only `swiftc --version` (Expo's ExpoModulesJSI build script) is answered.
    static let runnable: Set<String> = ["lipo", "otool", "nm", "ar", "ranlib", "libtool"]

    /// `xcrun [--sdk S] <tool> args…` runs the `toolMap` equivalent of a `runnable` tool with the same arguments
    /// (`lipo` → `llvm-lipo`, `otool` → `llvm-otool`), or `swiftc --version`, or a `shimTools` shim with the same
    /// arguments; any other tool call is refused. `lipo -remove`, which `llvm-lipo` lacks, is mapped
    /// (`lipoRemoveArguments`); `lipoArchs` lists a file's architectures for it (nil: unreadable).
    public static func resolve(_ args: [String], sdk: DarwinSDK, which: (String) -> String?, shim: (String) -> String? = { _ in nil },
                               lipoArchs: (String) -> [String]? = { _ in nil }) throws -> Action {
        var rest = args[...]
        var sdkName = "iphoneos"   // default for our use: iOS builds
        while let a = rest.first {
            switch a {
            case "--sdk", "-sdk":
                rest = rest.dropFirst()
                guard let n = rest.first, DarwinSDK.platformDir[n] != nil else { throw Unsupported(argv: args) }
                sdkName = n; rest = rest.dropFirst()
            case "--show-sdk-path", "-show-sdk-path":
                guard rest.count == 1 else { throw Unsupported(argv: args) }
                return .output(try sdk.sdkPath(sdkName).path + "\n")
            case "--show-sdk-version", "-show-sdk-version":
                guard rest.count == 1 else { throw Unsupported(argv: args) }
                return .output(try sdk.sdkVersion(sdkName) + "\n")
            case "--show-sdk-platform-path", "-show-sdk-platform-path":
                guard rest.count == 1 else { throw Unsupported(argv: args) }
                return .output(try sdk.sdkPath(sdkName).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "\n")
            case "--find", "-find", "-f":
                rest = rest.dropFirst()
                guard let tool = rest.first, rest.count == 1 else { throw Unsupported(argv: args) }
                if tool == "ld" || tool == "ld64" { return .output(sdk.ld64.path + "\n") }
                if shimTools.contains(tool) {
                    guard let path = shim(tool) else { throw Unsupported(argv: args) }
                    return .output(path + "\n")
                }
                guard let linux = toolMap[tool], let path = which(linux) else { throw Unsupported(argv: args) }
                return .output(path + "\n")
            default:
                let toolArgs = Array(rest.dropFirst())
                if shimTools.contains(a) {
                    guard let path = shim(a) else { throw Unsupported(argv: args) }
                    return .exec(path: path, args: toolArgs)
                }
                guard !a.hasPrefix("-"), runnable.contains(a) || (a == "swiftc" && toolArgs == ["--version"]),
                      let linux = toolMap[a], let path = which(linux) else { throw Unsupported(argv: args) }
                if a == "lipo", toolArgs.contains("-remove") {
                    guard let mapped = lipoRemoveArguments(toolArgs, archs: lipoArchs) else { throw Unsupported(argv: args) }
                    return .exec(path: path, args: mapped)
                }
                return .exec(path: path, args: toolArgs)
            }
        }
        throw Unsupported(argv: args)
    }

    /// `lipo -remove <arch> [-remove <arch>…] -output <out> <in>`, as CocoaPods' `[CP] Embed Pods Frameworks` phase
    /// strips the architectures a build does not target from a vendored fat framework (a simulator build for arm64
    /// only, given `arm64 x86_64` slices). `llvm-lipo` has no `-remove`; its `<in> -extract <kept>… -output <out>`
    /// writes the same thing Apple's `lipo -remove` does: a fat file holding the remaining slices (measured: Xcode
    /// 27.0's lipo keeps the fat header for a single remaining slice too). nil (refused) for another shape, an input
    /// that is not fat, an architecture the input does not hold, or nothing left.
    public static func lipoRemoveArguments(_ args: [String], archs: (String) -> [String]?) -> [String]? {
        var remove: [String] = [], output: String?, input: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-remove":
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
                remove.append(args[i + 1]); i += 2
            case "-output":
                guard i + 1 < args.count, output == nil else { return nil }
                output = args[i + 1]; i += 2
            case let a where a.hasPrefix("-"):
                return nil
            default:
                guard input == nil else { return nil }
                input = args[i]; i += 1
            }
        }
        guard !remove.isEmpty, let output, let input, let present = archs(input), present.count > 1,
              remove.allSatisfy(present.contains) else { return nil }
        let kept = present.filter { !remove.contains($0) }
        guard !kept.isEmpty else { return nil }
        return [input] + kept.flatMap { ["-extract", $0] } + ["-output", output]
    }
}
