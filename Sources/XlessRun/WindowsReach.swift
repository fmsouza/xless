import Foundation

/// What of Windows a native build in WSL can get at without a socket of Windows' own (which the filter refuses): told by looking, with
/// no Windows program started.
public struct WindowsReach: Equatable, Sendable {
    /// Whatever asks for it can start a Windows program, `wsl.exe -u root` too.
    public var interop = false
    /// Windows' drives that are mounted to be written.
    public var drives: [String] = []
    /// What cannot be read of that which would say so: not known to be off.
    public var unread: [String] = []

    public init(interop: Bool = false, drives: [String] = [], unread: [String] = []) {
        self.interop = interop
        self.drives = drives
        self.unread = unread
    }

    public var isThere: Bool { interop || !drives.isEmpty || !unread.isEmpty }

    /// One line: what there is, what that means and how to turn it off. nil: there is nothing to say.
    public var note: String? {
        guard isThere else { return nil }
        func list(_ names: [String]) -> String { names.map(RunText.printable).joined(separator: ", ") }
        let what = (interop ? ["interop is on"] : []) + (drives.isEmpty ? [] : ["\(list(drives)) can be written"]) + (unread.isEmpty ? [] : ["\(list(unread)) cannot be read"])
        let settings = (interop || unread.contains(Self.sockets) ? ["[interop] enabled=false"] : []) + (!drives.isEmpty || unread.contains(Self.mounts) ? ["[automount] enabled=false"] : [])
        return "note: Windows \(interop || !drives.isEmpty ? "is" : "may be") in reach of the project's code here (\(what.joined(separator: ", "))): then it can run there as you, and be root in this distribution. "
            + "Put \(settings.joined(separator: " and ")) into /etc/wsl.conf, then wsl --terminate this distribution (docs/security.md#in-wsl)"
    }

    private static let sockets = "/run/WSL", mounts = "/proc/self/mountinfo"

    /// - Parameter root: where the system's files are, in tests.
    public static func look(root: String = "") -> WindowsReach {
        var out = WindowsReach()
        if let on = interop(root) { out.interop = on } else { out.unread.append(sockets) }
        if let text = text("\(root)\(mounts)") { out.drives = drives(text) } else { out.unread.append(mounts) }
        return out
    }

    /// nil: it cannot be read.
    private static func text(_ file: String) -> String? { FileManager.default.contents(atPath: file).map { String(decoding: $0, as: UTF8.self) } }

    /// WSL's first process has a socket also where interop is off (it answers no request then), and every session has one where it is
    /// on. Not looked at: binfmt_misc, which all distributions share, and $WSL_INTEROP, which is a word. nil: it cannot be told.
    private static func interop(_ root: String) -> Bool? {
        let directory = "\(root)\(sockets)", names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory) } catch {
            return (error as? CocoaError)?.code == .fileReadNoSuchFile ? false : nil // not in this mount namespace: a container
        }
        func type(_ name: String) -> FileAttributeType? { (try? FileManager.default.attributesOfItem(atPath: "\(directory)/\(name)"))?[.type] as? FileAttributeType }
        // (one whose kind cannot be told may be a socket)
        let found = names.filter { [.typeSocket, nil].contains(type($0)) }
        guard !found.isEmpty else { return false }
        let first = "1_interop"
        // (a link where systemd is the first process: to the one that WSL's has)
        let own = (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(directory)/\(first)")).map { ($0 as NSString).lastPathComponent } ?? first
        return found.contains { $0 != own } || !isOff(in: text("\(root)/etc/wsl.conf") ?? "")
    }

    /// `[interop] enabled` is false wherever it is said, in lines that WSL reads so for certain.
    private static func isOff(in text: String) -> Bool {
        var section = "", said: [Bool] = []
        for line in text.utf8.split(whereSeparator: { [UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains($0) }) {
            func trimmed(_ text: some StringProtocol) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            let line = trimmed(String(decoding: line.prefix { $0 != UInt8(ascii: "#") }, as: UTF8.self)).lowercased()
            if line.hasSuffix("\\") { return false } // it goes on in the next one
            if line.hasPrefix("[") { section = line; continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(trimmed)
            if section == "[interop]", parts.count == 2, parts[0] == "enabled" { said.append(["false", "0", "\"false\"", "\"0\""].contains(parts[1])) }
        }
        return !said.isEmpty && !said.contains(false)
    }

    /// Of /proc/self/mountinfo: a 9p or virtiofs that may be written is Windows' (WSL's own ones are read-only).
    static func drives(_ mounts: String) -> [String] {
        mounts.split(separator: "\n").compactMap { line -> String? in
            let words = line.split(separator: " ").map(String.init)
            guard let dash = words.firstIndex(of: "-"), words.count > 5, words.count > dash + 3, dash > 5 else { return nil }
            func writable(_ options: String) -> Bool { options.split(separator: ",").first == "rw" }
            guard ["9p", "virtiofs", "drvfs"].contains(words[dash + 1]), writable(words[5]), writable(words[dash + 3]) else { return nil }
            return unescaped(words[4])
        }
    }

    /// `\040` is a space.
    private static func unescaped(_ text: String) -> String {
        var out: [UInt8] = [], rest = Array(text.utf8)[...]
        while let byte = rest.popFirst() {
            let digits = rest.prefix(3)
            if byte == UInt8(ascii: "\\"), digits.count == 3, let code = UInt8(String(decoding: digits, as: UTF8.self), radix: 8) {
                out.append(code)
                rest = rest.dropFirst(3)
            } else { out.append(byte) }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
