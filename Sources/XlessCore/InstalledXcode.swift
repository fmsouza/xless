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

    /// Its program `name`, of the toolchain or of the developer directory; nil: it has none.
    public func tool(_ name: String) -> URL? {
        [toolchain, developer].map { $0.appendingPathComponent("usr/bin/\(name)") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Its program `name`, or the error that says it is not there.
    public func require(_ name: String, stage: Stage) throws -> URL {
        guard let tool = tool(name) else {
            throw XlessError(stage, "\(app.path) has no \(name)", fix: "reinstall Xcode, or choose another one with DEVELOPER_DIR")
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
/// What is found is used only when it is an Xcode of Apple's: its signature says so, and nobody but root and this user can change it
/// (`problem`). A process of this user's own can replace xless itself as well.
public struct XcodeFinder {
    let environment: [String: String]
    /// The developer directory of `xcode-select`.
    let selected: () -> String?
    /// Where Xcodes are installed.
    let applications: [URL]
    /// nil: its signature is Apple's; else why not.
    let isGenuine: (URL) -> String?

    public init(environment: [String: String], selected: @escaping () -> String?, applications: [URL], isGenuine: @escaping (URL) -> String?) {
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

    /// Why `xcode` is not used; nil: it is.
    func problem(of xcode: InstalledXcode) -> String? {
        for path in Self.guarded(xcode) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return "\(path) is not there" }
            if st.st_mode & S_IFMT == S_IFLNK { continue } // what it names is checked; a link's own mode says nothing
            if let problem = Self.problem(path: path, owner: st.st_uid, group: st.st_gid, mode: UInt16(st.st_mode & 0o7777), isDirectory: st.st_mode & S_IFMT == S_IFDIR, user: geteuid()) {
                return problem
            }
        }
        return isGenuine(xcode.app)
    }

    /// Every directory from / to the toolchain's programs, and the compiler.
    static func guarded(_ xcode: InstalledXcode) -> [String] {
        let swift = xcode.toolchain.appendingPathComponent("usr/bin/swift")
        var paths: [String] = [], at = ""
        for part in swift.path.split(separator: "/") {
            at += "/\(part)"
            paths.append(at)
        }
        if let real = realpath(swift.path, nil) {
            paths.append(String(cString: real))
            free(real)
        }
        let programs = xcode.developer.appendingPathComponent("usr").path
        return ["/"] + paths + [programs, programs + "/bin"].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// A file that another user could replace or change: `path`'s owner is neither root nor this user, or others may write it. The
    /// groups wheel and admin may (as /Applications has it): their members are administrators of this Mac.
    static func problem(path: String, owner: UInt32, group: UInt32, mode: UInt16, isDirectory: Bool, user: UInt32) -> String? {
        guard owner == 0 || owner == user else { return "\(path) belongs to another user" }
        let sticky = isDirectory && mode & 0o1000 != 0
        guard mode & 0o002 == 0 || sticky, mode & 0o020 == 0 || sticky || group == 0 || group == 80 else {
            return "\(path) can be written by other users"
        }
        return nil
    }

    /// Xcode as Apple signs it: with its own certificate, for the App Store, or with its Developer ID.
    static let requirement = #"identifier "com.apple.dt.Xcode" and (anchor apple or anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] or anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "59GAB85EFG")"#
    /// Its programs, which Apple signs as its own.
    static let programs = ["swift", "clang", "ld"]

    /// Why the signature of `app`, or of one of its programs, is not Apple's. Of the app its own code and Info.plist are checked, not
    /// the gigabytes of its resources (`--ignore-resources`), and the programs each.
    static func signatureProblem(_ app: URL) -> String? {
        func holds(_ path: String, _ requirement: String) -> Bool {
            (try? Shell.run("/usr/bin/codesign", ["--verify", "--ignore-resources", "-R=\(requirement)", path], stage: .sdk)) != nil
        }
        guard holds(app.path, requirement) else { return "its signature is not that of an Xcode of Apple's" }
        let xcode = InstalledXcode(app: app, version: "", build: "", source: "")
        for name in programs {
            guard let tool = xcode.tool(name) else { return "it has no \(name)" }
            guard holds(tool.path, "anchor apple") else { return "\(tool.path) is not signed by Apple" }
        }
        return nil
    }
}
