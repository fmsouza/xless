import Foundation

/// What of Windows a native build in WSL can get at without a socket of Windows' own (which the filter refuses): told by looking, with
/// no Windows program started.
public struct WindowsReach: Equatable, Sendable {
    /// Whatever asks for it can start a Windows program, `wsl.exe -u root` too.
    public var interop = false
    /// Windows' drives that are mounted to be written.
    public var drives: [String] = []

    public init(interop: Bool = false, drives: [String] = []) {
        self.interop = interop
        self.drives = drives
    }

    public var isThere: Bool { interop || !drives.isEmpty }

    /// One line: what there is, what that means and how to turn it off. nil: there is nothing to say.
    public var note: String? {
        guard isThere else { return nil }
        let what = (interop ? ["interop is on"] : []) + (drives.isEmpty ? [] : ["\(drives.map(RunText.printable).joined(separator: ", ")) can be written"])
        let settings = (interop ? ["[interop] enabled=false"] : []) + (drives.isEmpty ? [] : ["[automount] enabled=false"])
        return "note: Windows is in reach of the project's code here (\(what.joined(separator: ", "))): it can run there as you, and be root in this distribution. "
            + "Put \(settings.joined(separator: " and ")) into /etc/wsl.conf, then wsl --terminate this distribution (docs/security.md#in-wsl)"
    }

    /// - Parameter root: where the system's files are, in tests.
    public static func look(root: String = "") -> WindowsReach {
        WindowsReach(interop: interop(root), drives: drives((try? String(contentsOfFile: "\(root)/proc/self/mountinfo", encoding: .utf8)) ?? ""))
    }

    /// WSL's first process has a socket also where interop is off (it answers no request then), and every session has one where it is
    /// on. Not looked at: binfmt_misc, which all distributions share, and $WSL_INTEROP, which is a word.
    private static func interop(_ root: String) -> Bool {
        let directory = "\(root)/run/WSL"
        func type(_ name: String) -> FileAttributeType? { (try? FileManager.default.attributesOfItem(atPath: "\(directory)/\(name)"))?[.type] as? FileAttributeType }
        let sockets = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { type($0) == .typeSocket }
        guard !sockets.isEmpty else { return false } // not in this mount namespace: a container
        let first = "1_interop"
        // (a link where systemd is the first process: to the one that WSL's has)
        let own = (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(directory)/\(first)")).map { ($0 as NSString).lastPathComponent } ?? first
        return sockets.contains { $0 != own } || !isOff(in: (try? String(contentsOfFile: "\(root)/etc/wsl.conf", encoding: .utf8)) ?? "")
    }

    /// `[interop] enabled` is false wherever it is said.
    private static func isOff(in text: String) -> Bool {
        var section = "", said: [Bool] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("["), line.hasSuffix("]") { section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if section == "interop", parts.count == 2, parts[0] == "enabled" { said.append(["false", "0"].contains(parts[1].trimmingCharacters(in: ["\""]))) }
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
