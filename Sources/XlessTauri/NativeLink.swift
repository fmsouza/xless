import Foundation
import XlessCore

/// The app target's own native code: compiling its Objective-C/C sources and linking the executable with clang and
/// the SDK bundle's ld64.lld. The flags are Xcode's (from the Mac reference build's activity log) with the changes a
/// Linux host needs, recorded in docs/research/tauri-ios-contract.md ("Linux build — spike A findings", step 7 and
/// "Fixes the Mac line needed on Linux"; spike B difference 9 for binary dependencies).
public enum NativeLink {
    public struct LinkInputs: Equatable, Sendable {
        public var objects: [String]
        public var libraryPaths: [String]
        /// `-l<name>`.
        public var libraries: [String]
        /// Static libraries passed by path (the Swift aggregate).
        public var archives: [String]
        public var frameworkPaths: [String]
        /// Binary-dependency frameworks (`-framework <name>`, next to their link flags).
        public var frameworks: [String]
        /// The overlay's `linkFlags`, then each binary dependency's; placed where Xcode puts OTHER_LDFLAGS.
        public var linkFlags: [String]
        public var sdkFrameworks: [String]
        public var clangRuntime: String
        /// The Swift runtime and overlay dirs the autolink records in the Swift objects resolve against.
        public var swiftLibPaths: [String]
        public var minOS: String
        public var sdk: URL
        /// nil: the compiler's own linker (Xcode's).
        public var ld64: URL?
        public var output: String

        public init(objects: [String], libraryPaths: [String], libraries: [String], archives: [String], frameworkPaths: [String],
                    frameworks: [String], linkFlags: [String], sdkFrameworks: [String], clangRuntime: String, swiftLibPaths: [String],
                    minOS: String, sdk: URL, ld64: URL?, output: String) {
            self.objects = objects; self.libraryPaths = libraryPaths; self.libraries = libraries; self.archives = archives
            self.frameworkPaths = frameworkPaths; self.frameworks = frameworks; self.linkFlags = linkFlags
            self.sdkFrameworks = sdkFrameworks; self.clangRuntime = clangRuntime; self.swiftLibPaths = swiftLibPaths
            self.minOS = minOS; self.sdk = sdk; self.ld64 = ld64; self.output = output
        }
    }

    /// `clang` arguments compiling one source. Xcode's CompileC flags for the target (release) minus header maps,
    /// `-g`/`-gmodules` and diagnostics plumbing; C++ and Objective-C flags only for the languages that take them.
    public static func compileArguments(source: String, object: String, headerSearchPaths: [String], minOS: String, sdk: URL) -> [String] {
        let ext = (source as NSString).pathExtension
        let language = ["m": "objective-c", "mm": "objective-c++", "c": "c"][ext] ?? "c++"
        let cxx = ext == "mm" || language == "c++", objc = ext == "m" || ext == "mm"
        var args = ["-x", language, "-target", "arm64-apple-ios\(minOS)", "-isysroot", sdk.path]
        if cxx { args += ["-std=gnu++14", "-stdlib=libc++"] }
        if objc { args += ["-fobjc-arc", "-fobjc-weak"] }
        args.append("-fmodules")
        if cxx { args.append("-fno-cxx-modules") }
        args += ["-fpascal-strings", "-Os", "-fno-common", "-DNS_BLOCK_ASSERTIONS=1", "-DOBJC_OLD_DISPATCH_PROTOTYPES=0", "-fvisibility=hidden"]
        if cxx { args.append("-fvisibility-inlines-hidden") }
        for p in headerSearchPaths { args += ["-I", p] }
        return args + ["-c", source, "-o", object]
    }

    /// `clang++` arguments for the executable, in the contract's order. Changes from Xcode's line: ld64.lld through
    /// `-fuse-ld` with `-mlinker-version=907` (so the driver passes `-platform_version`), an explicit
    /// `libclang_rt.ios.a` (the Linux clang's resource dir has none), the Swift aggregate by path, ld64 bookkeeping
    /// flags dropped, and no `-lc++` beyond the driver's.
    public static func linkArguments(_ i: LinkInputs) -> [String] {
        var args = ["-target", "arm64-apple-ios\(i.minOS)", "-isysroot", i.sdk.path, "-Os"] + (i.ld64.map { ["-fuse-ld=\($0.path)", "-mlinker-version=907"] } ?? [])
        for p in i.libraryPaths + i.swiftLibPaths.filter({ !i.libraryPaths.contains($0) }) { args += ["-L", p] }
        for p in i.frameworkPaths { args += ["-F", p] }
        args += i.objects
        args += ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks", "-Xlinker", "-dead_strip"]
        args += ["-stdlib=libc++", "-fobjc-arc", "-fobjc-link-runtime"]
        args += i.linkFlags
        for f in i.frameworks { args += ["-framework", f] }
        args += i.libraries.map { "-l\($0)" }
        args += i.archives
        args.append(i.clangRuntime)
        for f in i.sdkFrameworks { args += ["-framework", f] }
        return args + ["-o", i.output]
    }

    /// An Xcode build setting value expanded and split into words: `$(VAR)` and `${VAR}` from `vars` (unset → empty,
    /// as in Xcode), `$(inherited)` dropped (there is nothing to inherit), double quotes group words.
    public static func expandSettings(_ value: String, vars: [String: String]) -> [String] {
        var words: [String] = [], current = "", inQuotes = false, started = false
        for ch in value {
            if ch == "\"" { inQuotes.toggle(); started = true; continue }
            if ch.isWhitespace && !inQuotes {
                if started { words.append(current) }
                current = ""; started = false
                continue
            }
            current.append(ch); started = true
        }
        if started { words.append(current) }
        return words.compactMap { word -> String? in
            if word == "$(inherited)" || word == "${inherited}" { return nil }
            let expanded = word.replacing(/\$[({]([A-Za-z0-9_]+)[)}]/) { vars[String($0.1)] ?? "" }
            return expanded.isEmpty ? nil : expanded
        }
    }

    /// A target setting for an arm64 iOS device build: `KEY[arch=arm64]`, then `KEY[sdk=iphoneos*]`, then `KEY`.
    public static func setting(_ key: String, in settings: [String: String]) -> String? {
        settings["\(key)[arch=arm64]"] ?? settings["\(key)[sdk=iphoneos*]"] ?? settings[key]
    }

    /// Link inputs from the target's `dependencies` and the overlay. Binary dependencies (xcframeworks the overlay
    /// installs) come first: their slice on `-F`, the overlay's `linkFlags` then theirs, one `-framework` each.
    /// `project.yml` dependencies: `libapp.a` (where xcode-script puts the Rust staticlib) is skipped, because the build
    /// links cargo's output in place; another `lib<x>.a` → `-l<x>`; a framework or xcframework not already linked → `-F`/`-framework`;
    /// `sdk:` frameworks in order, `sdk: lib<x>.tbd` → `-l<x>`. A CocoaPods `Pods_<target>` framework and duplicates are
    /// dropped (spike B, open question 5).
    public static func dependencyInputs(target: XcodeGenTarget, overlay: TauriOverlay, workRoot: URL, appleDir: String) throws
        -> (libraries: [String], frameworkPaths: [String], frameworks: [String], linkFlags: [String], sdkFrameworks: [String]) {
        var libraries: [String] = [], frameworkPaths: [String] = [], frameworks: [String] = [], sdkFrameworks: [String] = []
        var flags = overlay.linkFlags
        func addFramework(_ name: String, dir: URL) {
            guard !frameworks.contains(name), !name.hasPrefix("Pods_") else { return }
            frameworks.append(name)
            if !frameworkPaths.contains(dir.path) { frameworkPaths.append(dir.path) }
        }
        func addLibrary(_ name: String) { if !libraries.contains(name) { libraries.append(name) } }
        func libName(_ file: String) -> String? {
            guard file.hasPrefix("lib") else { return nil }
            for ext in [".a", ".tbd", ".dylib"] where file.hasSuffix(ext) { return String(file.dropFirst(3).dropLast(ext.count)) }
            return nil
        }
        func xcframework(_ url: URL) throws -> URL {
            guard let slice = AppAssembler.deviceSlice(of: url) else {
                throw XlessError(.build, "\(url.lastPathComponent) has no iOS device slice", fix: "check that the xcframework contains an ios-arm64 library")
            }
            return slice
        }

        for dep in overlay.binaryDependencies {
            flags += dep.linkFlags
            let url = workRoot.appendingPathComponent(dep.to)
            let name = url.deletingPathExtension().lastPathComponent
            switch url.pathExtension {
            case "xcframework": addFramework(name, dir: try xcframework(url))
            case "framework": addFramework(name, dir: url.deletingLastPathComponent())
            default: break
            }
        }
        for dep in target.dependencies {
            switch dep {
            case .framework(let path, _, _):
                let url = workRoot.appendingPathComponent(appleDir).appendingPathComponent(path)
                let file = url.lastPathComponent, name = url.deletingPathExtension().lastPathComponent
                if file == "libapp.a" { continue }   // the Rust staticlib xcode-script copies; xless links cargo's output in place
                if let lib = libName(file) { addLibrary(lib); continue }
                switch url.pathExtension {
                case "xcframework": if !frameworks.contains(name) { addFramework(name, dir: try xcframework(url)) }
                case "framework": addFramework(name, dir: url.deletingLastPathComponent())
                default: break
                }
            case .sdk(let item):
                if let lib = libName(item) { addLibrary(lib); continue }
                let name = item.hasSuffix(".framework") ? String(item.dropLast(".framework".count)) : item
                if !sdkFrameworks.contains(name), !frameworks.contains(name) { sdkFrameworks.append(name) }
            }
        }
        return (libraries, frameworkPaths, frameworks, flags, sdkFrameworks)
    }
}
