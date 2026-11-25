import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An Xcode of this Mac, whose tools build natively. Its public command-line tools are started as programs, by their path in it;
/// nothing of it is linked, copied or changed.
public struct InstalledXcode: Sendable, Equatable {
    /// Its path without a link in it.
    public let app: URL
    /// `27.2`
    public let version: String
    /// `27B52`
    public let build: String
    /// What named it: `DEVELOPER_DIR`, `xcode-select` or `installed`.
    public let source: String

    public init(app: URL, version: String, build: String, source: String) {
        self.app = app; self.version = version; self.build = build; self.source = source
    }

    public var developer: URL { app.appendingPathComponent("Contents/Developer") }
    public var toolchain: URL { developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain") }

    /// The line a build says it with.
    public var summary: String { "Xcode \(version) (\(build)) at \(app.path) (\(source))" }

    /// The programs of it that xless starts: these, and no others.
    public enum Program: String, Sendable, CaseIterable {
        case swift, actool, ibtool, xcodebuild
        case installNameTool = "install_name_tool"

        /// What Apple signs it as.
        var identifier: String {
            switch self {
            case .swift: "com.apple.swift-frontend"
            case .xcodebuild: "com.apple.dt.xcodebuild"
            case .actool, .ibtool, .installNameTool: "com.apple.\(rawValue)"
            }
        }
    }

    /// Its `program`, of the toolchain or of the developer directory; nil: it has none.
    public func tool(_ program: Program) -> URL? {
        [toolchain, developer].map { $0.appendingPathComponent("usr/bin/\(program.rawValue)") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Its `program`, or the error that says it is not there.
    public func require(_ program: Program, stage: Stage) throws -> URL {
        guard let tool = tool(program) else {
            throw XlessError(stage, "\(app.path) has no \(program.rawValue)", fix: "reinstall Xcode, or choose another one with DEVELOPER_DIR")
        }
        return tool
    }

    /// What its tools find changed in `base` (nil: removed): this Xcode is the one Apple's tools use, its toolchain is first on PATH,
    /// and nothing else chooses a toolchain, an SDK, a compiler or a library for them.
    public func environment(_ base: [String: String]) -> [String: String?] {
        var changes: [String: String?] = [:]
        for name in base.keys where Self.chosenElsewhere.contains(name) || name.hasPrefix("DYLD_") { changes.updateValue(nil, forKey: name) }
        changes["DEVELOPER_DIR"] = developer.path
        changes["PATH"] = "\(toolchain.path)/usr/bin:\(base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
        return changes
    }

    static let chosenElsewhere: Set<String> = [
        "SDKROOT", "TOOLCHAINS", "XCODE_DEFAULT_TOOLCHAIN_OVERRIDE", "XCODE_EXTRA_PLATFORM_FOLDERS", "XCODE_DEVELOPER_DIR_PATH", "SWIFT_EXEC", "SWIFT_EXEC_MANIFEST",
        "SWIFT_DRIVER_SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC", "CC", "CXX", "LD", "AR", "LIBTOOL", "RANLIB", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS",
        "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "LIBRARY_PATH", "LD_LIBRARY_PATH",
        "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET",
    ]
}

/// Finds the Xcode to build with: DEVELOPER_DIR's (Apple's own setting, which its tools read too), else the one `xcode-select`
/// names, else the newest of /Applications and ~/Applications. An `xcode:` pin takes the first of these that is that version; a
/// DEVELOPER_DIR that is another is refused, since the user named it.
///
/// What is found is used only when the programs that xless starts, and those that they start, are Apple's by their signature, and
/// nobody but root and this user can change them (`problem`). A process of this user's own can replace xless itself as well; the
/// SDKs and the rest of Xcode's files are not looked at.
public struct XcodeFinder {
    let environment: [String: String]
    /// The developer directory of `xcode-select`.
    let selected: () -> String?
    /// Where Xcodes are installed.
    let applications: [URL]
    /// nil: its signature is Apple's; else why not.
    let isGenuine: (InstalledXcode) -> String?

    public init(environment: [String: String], selected: @escaping () -> String?, applications: [URL], isGenuine: @escaping (InstalledXcode) -> String?) {
        self.environment = environment; self.selected = selected; self.applications = applications; self.isGenuine = isGenuine
    }

    /// Of this Mac.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        self.init(environment: environment, selected: {
            var base = environment
            base["DEVELOPER_DIR"] = nil // it would say that one again
            return (try? Shell.run("/usr/bin/xcode-select", ["-p"], env: ["DEVELOPER_DIR": nil], baseEnvironment: base, stage: .sdk))?.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }, applications: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")], isGenuine: Self.signatureProblem)
    }

    public func find(pin: String?, stage: Stage) throws -> InstalledXcode {
        func fits(_ xcode: InstalledXcode) -> Bool { pin.map { DottedVersion($0) == DottedVersion(xcode.version) } ?? true }
        func checked(_ xcode: InstalledXcode) throws -> InstalledXcode {
            guard let problem = problem(of: xcode) else { return xcode }
            throw XlessError(stage, "\(xcode.summary) is not used: \(problem)", fix: "reinstall Xcode from the App Store or https://developer.apple.com/download, or choose another one with DEVELOPER_DIR")
        }
        if let given = environment["DEVELOPER_DIR"], !given.isEmpty {
            guard given.hasPrefix("/"), let xcode = xcode(at: given, source: "DEVELOPER_DIR") else {
                throw XlessError(stage, "DEVELOPER_DIR=\(given) is not in an Xcode", fix: "set it to <Xcode.app>/Contents/Developer, or unset it")
            }
            guard fits(xcode) else {
                throw XlessError(stage, "xcode: \"\(pin ?? "")\" is pinned, but DEVELOPER_DIR names \(xcode.summary)", fix: "set DEVELOPER_DIR to that Xcode, or unset it")
            }
            return try checked(xcode)
        }
        let path = selected()
        let chosen = path.flatMap { xcode(at: $0, source: "xcode-select") }
        if let chosen, fits(chosen) { return try checked(chosen) }
        let installed = installed()
        var refused: String?
        for xcode in installed where fits(xcode) {
            guard let problem = problem(of: xcode) else { return xcode }
            refused = refused ?? "\(xcode.summary) is not used: \(problem)"
        }
        let get = "install Xcode from the App Store (or an Xcode .xip from https://developer.apple.com/download) and open it once; or build in Docker with --docker (after xless setup --docker --xcode <Xcode.xip>)"
        if let refused { throw XlessError(stage, refused, fix: get) }
        if let pin {
            let have = ([chosen].compactMap { $0 } + installed).reduce(into: [String]()) { names, xcode in
                let name = "\(xcode.version) (\(xcode.build))"
                if !names.contains(name) { names.append(name) }
            }
            throw XlessError(stage, "xcode: \"\(pin)\" is pinned, but this Mac has \(have.isEmpty ? "no Xcode" : "Xcode \(have.joined(separator: ", "))")",
                             fix: "install Xcode \(pin) next to it (any name /Applications/Xcode*.app), change the pin, or build in Docker with --docker")
        }
        let tools = path.map { $0.hasSuffix("/CommandLineTools") } == true ? " (the Command Line Tools alone have no iOS SDK)" : ""
        throw XlessError(stage, "no Xcode on this Mac\(tools)", fix: get)
    }

    /// Those of the applications' directories, the newest first.
    func installed() -> [InstalledXcode] {
        applications.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
                .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
                .compactMap { xcode(at: directory.appendingPathComponent($0).path, source: "installed") }
        }.enumerated().sorted { a, b in
            let one = DottedVersion(a.element.version), two = DottedVersion(b.element.version)
            if let one, let two, one != two { return one > two }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The Xcode that `path` is, or is the developer directory of.
    func xcode(at path: String, source: String) -> InstalledXcode? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        var app = URL(fileURLWithPath: String(cString: resolved))
        if app.path.hasSuffix(".app/Contents/Developer") { app = app.deletingLastPathComponent().deletingLastPathComponent() }
        guard app.pathExtension == "app",
              let plist = try? Plist.read(app.appendingPathComponent("Contents/version.plist"), stage: .sdk),
              let version = plist["CFBundleShortVersionString"] as? String, DottedVersion(version) != nil,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty, build.utf8.allSatisfy({ ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7a || $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }
        return InstalledXcode(app: app, version: version, build: build, source: source)
    }

    // MARK: - Is it an Xcode of Apple's

    /// Why `xcode` is not used; nil: it is. Nothing of it was started by then.
    func problem(of xcode: InstalledXcode) -> String? {
        Self.guarded(xcode).lazy.compactMap { TrustedPath.problem($0) }.first ?? isGenuine(xcode)
    }

    /// The programs of `xcode` that are there: those that xless starts, and those that they start (as far as they are known).
    static func programs(of xcode: InstalledXcode) -> [(path: String, identifier: String?)] {
        let directories = [xcode.toolchain, xcode.developer].map { $0.appendingPathComponent("usr/bin").path }
        let named: [(String, String?)] = InstalledXcode.Program.allCases.map { ($0.rawValue, $0.identifier) } + [
            ("swift-build", "com.apple.swift-package"), // which `swift build` is, and which puts plugins in their sandbox
            ("swift-package", "com.apple.swift-package"), ("swiftc", "com.apple.swift-frontend"), ("swift-frontend", "com.apple.swift-frontend"),
            ("clang", "com.apple.clang"), ("ld", "com.apple.ld"), // (what the toolchain below is to have)
        ] + ["swift-driver", "swift-plugin-server", "clang++", "libtool", "lipo", "ar", "strip", "dsymutil", "codesign_allocate", "ibtoold"].map { ($0, nil) }
        let services: [(String, String?)] = [
            (xcode.developer.path + "/Library/Xcode/Agents/AssetCatalogAgent-AssetRuntime", nil),
            (xcode.app.path + "/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/MacOS/SWBBuildService", "com.apple.dt.SWBBuildService"),
        ]
        return (directories.flatMap { directory in named.map { ("\(directory)/\($0.0)", $0.1) } } + services)
            .filter { FileManager.default.fileExists(atPath: $0.0) }.map { (path: $0.0, identifier: $0.1) }
    }

    /// What nobody else may be able to change: those programs, and the directories that they find others and their libraries in.
    static func guarded(_ xcode: InstalledXcode) -> [String] {
        let toolchain = xcode.toolchain.path
        return programs(of: xcode).map(\.path)
            + [toolchain + "/usr/bin", toolchain + "/usr/lib", toolchain + "/usr/libexec", xcode.developer.path + "/usr/bin", xcode.developer.path + "/usr/lib",
               xcode.developer.path + "/Library/Xcode", xcode.app.path + "/Contents/SharedFrameworks", xcode.app.path + "/Contents/Frameworks"]
                .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Why the signature of `xcode`, or of one of its programs, is not Apple's.
    public static func signatureProblem(_ xcode: InstalledXcode) -> String? {
        for name in ["swift", "swift-build", "clang", "ld"] where !FileManager.default.isExecutableFile(atPath: xcode.toolchain.path + "/usr/bin/\(name)") { return "it has no \(name)" }
        if let problem = AppleSignature.problem(xcode: xcode.app.path) { return problem }
        return programs(of: xcode).lazy.compactMap { program in
            // (a link's name says nothing: what it names is started, and is what is signed)
            AppleSignature.problem(program: URL(fileURLWithPath: program.path).resolvingSymlinksInPath().path, identifier: program.identifier)
        }.first
    }
}
