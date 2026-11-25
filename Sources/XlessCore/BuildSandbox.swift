import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What an overlay's app is built in on a Mac: the code of a Tauri, Cargo or React Native app's build (npm scripts, build.rs, gems, pods,
/// Xcode's build phases) is not written by xless and is not looked at, and in the images a container keeps it from the rest of the
/// machine. Here `sandbox-exec`, the command-line tool of macOS's own sandbox, does: a whole xless runs in it (`prepare` to
/// `finalize`), with everything that it starts and whatever those leave running. docs/security.md says what that keeps away and what
/// not.
public struct BuildSandbox: Sendable, Equatable {
    /// What is readable of what is closed: files and directories with all that is below them.
    public var reads: [String]
    /// What is writable; also readable.
    public var writes: [String]
    /// Not writable, though it is below what is: where xless puts what it makes of the build outside the sandbox.
    public var readOnly: [String]
    /// Directories that stay themselves where they are (a link in their place would lead xless elsewhere), as those of `writes` do.
    public var fixed: [String]
    /// Never readable or writable, wherever it is.
    public var secrets: [String]
    /// Closed for reading, but for those, and not there for whoever looks: where users keep their files (and tools look for the
    /// settings of a user, in every directory above the work copy). Nothing is writable anywhere, but for `writes`.
    public var closed: [String]

    public static let tool = "/usr/bin/sandbox-exec"

    public init(reads: [String], writes: [String], readOnly: [String] = [], fixed: [String] = [], secrets: [String], closed: [String]) {
        self.reads = reads; self.writes = writes; self.readOnly = readOnly; self.fixed = fixed; self.secrets = secrets; self.closed = closed
    }

    /// The home directories, the other volumes, and the directories for temporary files, which xless's own are in too.
    public static let privatePlaces = ["/Users", "/Volumes", "/private/tmp", "/private/var/tmp", "/private/var/folders", "/private/var/root"]

    /// The services of the system that build tools look for; every other is refused: the keychain, launchd's jobs, Apple events, the
    /// pasteboard, the simulators and the window server are services.
    static let services = [
        "com.apple.system.opendirectoryd.libinfo", "com.apple.system.opendirectoryd.membership", "com.apple.bsd.dirhelper",
        "com.apple.FSEvents", "com.apple.trustd.agent", "com.apple.trustd", "com.apple.system.notification_center",
        "com.apple.SystemConfiguration.configd", "com.apple.SystemConfiguration.DNSConfiguration", "com.apple.logd",
    ]

    /// The sandbox's rules. (The last that fits counts; what is more specific than `file-read*` would win over it, so it is not used.)
    public func profile() throws -> String {
        func paths(_ all: [String]) throws -> String {
            try all.map { "(subpath \(try Self.quoted(Self.real($0))))" }.joined(separator: " ")
        }
        var rules = ["(version 1)", "(allow default)", "(deny file-write*)"]
        func add(_ words: String, _ all: [String]) throws { if !all.isEmpty { rules.append("(\(words) \(try paths(all)))") } }
        try add("allow file-write*", writes)
        try add("deny file-write*", readOnly)
        let fixed = try (writes + fixed).map { " (literal \(try Self.quoted(Self.real($0))))" }.joined()
        if !fixed.isEmpty { rules.append("(deny file-write-create file-write-unlink\(fixed))") }
        rules.append(#"(allow file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))"#)
        // xcodebuild saves files in the user's directory for temporary files whatever TMPDIR says, below directories with names of its
        // own, and renames them into their place. What others have there cannot be listed, read or (but for a name that somebody guesses)
        // changed.
        if let temporary = Self.userTemporaryDirectory {
            rules.append("(allow file-write* (regex #\"^\(try Self.pattern(Self.real(temporary)))/TemporaryItems(/NSIRD_|$)\"))")
        }
        let read = "file-read-data file-read-xattr file-read-metadata"
        try add("deny \(read)", closed)
        // the way to what is open
        let above = Set((reads + writes).flatMap { Self.above(Self.real($0)) }).sorted()
        if !above.isEmpty { rules.append("(allow file-read-metadata \(try above.map { "(literal \(try Self.quoted($0)))" }.joined(separator: " ")))") }
        rules.append(#"(deny file-read-data file-write* (regex #"^/dev/tty"))"#)
        try add("allow \(read)", reads + writes)
        try add("deny \(read) file-write*", secrets)
        rules += ["(deny mach-lookup)", "(allow mach-lookup \(Self.services.map { "(global-name \"\($0)\")" }.joined(separator: " ")))"]
        let sockets = try writes.map { " (remote unix-socket (subpath \(try Self.quoted(Self.real($0)))))" }.joined()
        rules += ["(deny network-outbound (remote unix-socket))", #"(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder"))"# + sockets + ")"]
        rules += ["(deny job-creation)", "(deny appleevent-send)", "(deny lsopen)", "(deny mach-priv-task-port)", "(deny process-info* (target others))",
                  "(deny signal)", "(allow signal (target self) (target pgrp) (target same-sandbox))"]
        return rules.joined(separator: "\n") + "\n"
    }

    /// The program and its arguments, in the sandbox.
    public func command(_ program: String, _ arguments: [String]) throws -> (program: String, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: Self.tool) else {
            throw XlessError(.prepare, "\(Self.tool) is not on this Mac, and the app's build code does not run without the sandbox", fix: "build in Docker: add --docker")
        }
        return (Self.tool, ["-p", try profile(), program] + arguments)
    }

    /// Whether this process is in such a sandbox, seen and not told: it can neither make a file in the user's directory for temporary
    /// files nor list the home directory, and the system says that it may not. (Both are the user's own: outside it can.)
    public static func isInForce() -> Bool {
        guard let temporary = userTemporaryDirectory, let home = userHome else { return false }
        let probe = "\(temporary)/xless-sandbox-\(UUID().uuidString)"
        let made = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if made >= 0 {
            close(made)
            unlink(probe)
            return false
        }
        guard errno == EPERM else { return false }
        if let listed = opendir(home) {
            closedir(listed)
            return false
        }
        return errno == EPERM
    }

    // MARK: - Paths

    /// Without a link in it, as the sandbox sees paths; of one that is not there yet, as far as there is something.
    public static func real(_ path: String) -> String {
        var at = path, rest: [String] = []
        while true {
            if let resolved = realpath(at, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.reversed().joined(separator: "/")
            }
            let url = URL(fileURLWithPath: at)
            guard at != "/", !url.lastPathComponent.isEmpty else { return path }
            rest.append(url.lastPathComponent)
            at = url.deletingLastPathComponent().path
        }
    }

    /// The directories that `path` is in, but for /.
    static func above(_ path: String) -> [String] {
        path.split(separator: "/").dropLast().reduce(into: []) { all, name in all.append("\(all.last ?? "")/\(name)") }
    }

    /// Of this user, whatever the environment says.
    public static var userHome: String? { getpwuid(geteuid()).map { String(cString: $0.pointee.pw_dir) } }

    static var userTemporaryDirectory: String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        #else
        return nil
        #endif
    }

    /// Whether `path` is `directory` or below it.
    public static func isBelow(_ path: String, _ directory: String) -> Bool {
        directory == "/" || path == directory || path.hasPrefix(directory + "/")
    }

    private static func checked(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path != "/", !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw XlessError(.prepare, "the build's sandbox cannot have \(TerminalText.escaped(path)) in its rules", fix: "use a directory with a plain path, or build in Docker: add --docker")
        }
        return path
    }

    static func quoted(_ path: String) throws -> String {
        "\"" + (try checked(path)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// For a regular expression of a rule.
    static func pattern(_ path: String) throws -> String {
        try checked(path).reduce(into: "") { out, c in out += "\\^$.|?*+()[]{}\"".contains(c) ? "\\\(c)" : String(c) }
    }
}
