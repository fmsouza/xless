import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import XlessCore

/// A key Apple offers once (an App Store Connect API key, an auth key) that the secret store could not keep after it was
/// created: rather than drop it, xless writes it to a new file the user then imports (#141).
///
/// Where: `$XDG_RUNTIME_DIR` (yours alone, 0700, a tmpfs emptied at logout on systemd hosts) when it is usable, else a
/// path asked on the terminal. The file is created new (O_EXCL, never through a symlink) with mode 0600; nothing is
/// ever overwritten. With neither, the key is lost and the error says why.
struct KeyRescue: Sendable {
    var env: [String: String]
    /// Asks the terminal (the prompt given) for a path; nil when there is no terminal or it was closed.
    var ask: @Sendable (String) -> String?

    enum Outcome: Equatable {
        /// Written to `path` (absolute); `temporary` when it is in `$XDG_RUNTIME_DIR`.
        case saved(path: String, temporary: Bool)
        /// Not written: why.
        case notSaved(String)
    }

    /// The process's environment and terminal.
    static var standard: KeyRescue {
        KeyRescue(env: ProcessInfo.processInfo.environment, ask: { prompt in
            guard !InputGate.isOff, let terminal = try? TerminalPrompter.forSecretStore() else { return nil }
            return try? terminal.ask(prompt)
        })
    }

    /// Writes `secret` to a new file: `$XDG_RUNTIME_DIR/xless-rescued-AuthKey_<KEY_ID>.p8` (`.2.p8`, `.3.p8`… when taken),
    /// else a path the terminal gives.
    func save(_ secret: SecretBytes, keyID: String) -> Outcome {
        var notes: [String] = []
        if let dir = runtimeDirectory(&notes) {
            let base = "xless-rescued-AuthKey_\(keyID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })"
            var taken = true
            for n in 1...50 {
                let path = "\(dir)/\(base)\(n == 1 ? "" : ".\(n)").p8"
                switch Self.create(secret, at: path) {
                case .written: return .saved(path: path, temporary: true)
                case .exists: continue
                case .failed(let why): notes.append("cannot write \(path): \(why)")
                }
                taken = false
                break
            }
            if taken { notes.append("\(dir) already has 50 files \(base)*.p8") }
        }
        var prompt = "The secret store could not keep the private key of \(keyID), which Apple offers once. Path of a new file to save it to (mode 0600; Enter to give up): "
        while let answer = ask(prompt) {
            var path = answer.trimmingCharacters(in: .whitespaces)
            if path.isEmpty { return .notSaved((notes + ["no file was given"]).joined(separator: "; ")) }
            if path.hasPrefix("~/"), let home = env["HOME"], home.hasPrefix("/") { path = home + path.dropFirst() }
            if !path.hasPrefix("/") { path = FileManager.default.currentDirectoryPath + "/" + path }
            switch Self.create(secret, at: path) {
            case .written: return .saved(path: path, temporary: false)
            case .exists: prompt = "\(path) exists (xless never overwrites a file). Another path (Enter to give up): "
            case .failed(let why): prompt = "Cannot write \(path): \(why). Another path (Enter to give up): "
            }
        }
        return .notSaved((notes + ["there is no terminal to ask where to save it"]).joined(separator: "; "))
    }

    /// The error for such a key: saved, with the exact `xless secrets import` command (`entry`, then `importOptions`)
    /// and how to give it up (`revoke`); else `lost` with the reason the file could not be written either.
    func failure(_ secret: SecretBytes, noun: String, keyID: String, because why: String, entry: String, importOptions: [String],
                 revoke: String, lost: (String) -> XlessError) -> XlessError {
        switch save(secret, keyID: keyID) {
        case .notSaved(let reason):
            return lost("\(why); it could not be saved to a file either (\(reason))")
        case .saved(let path, let temporary):
            let command = (["xless", "secrets", "import", entry, "--file", path] + importOptions).map(ShellWord.quoted).joined(separator: " ")
            return XlessError(.account, "\(noun) \(keyID) was created, but \(why); its private key is saved in \(path) (mode 0600\(temporary ? "; $XDG_RUNTIME_DIR is emptied when you log out" : ""))",
                              fix: "put it into the secret store now: `\(command)` (it offers to delete the file afterwards); if you do not want the key, delete the file and revoke it (`\(revoke)`)")
        }
    }

    /// `$XDG_RUNTIME_DIR` when it is an absolute path to a real directory of yours that no one else can enter.
    private func runtimeDirectory(_ notes: inout [String]) -> String? {
        guard let dir = env["XDG_RUNTIME_DIR"], !dir.isEmpty else { return nil }
        guard dir.hasPrefix("/") else { notes.append("XDG_RUNTIME_DIR is not an absolute path"); return nil }
        var st = stat()
        guard lstat(dir, &st) == 0 else { notes.append("cannot inspect XDG_RUNTIME_DIR \(dir): \(String(cString: strerror(errno)))"); return nil }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else {
            notes.append("XDG_RUNTIME_DIR \(dir) is not a private directory of yours (a symlink, another owner, or open to others)")
            return nil
        }
        return dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
    }

    enum Written: Equatable { case written, exists, failed(String) }

    /// A new file (O_EXCL, no symlink followed), mode 0600, written whole and synced; removed again when that fails.
    static func create(_ secret: SecretBytes, at path: String) -> Written {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno == EEXIST ? .exists : .failed(String(cString: strerror(errno))) }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = secret.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    off += n
                }
                return true
            }
        }
        var why = ok ? "" : String(cString: strerror(errno))
        if ok, fsync(fd) != 0 { ok = false; why = String(cString: strerror(errno)) }
        if close(fd) != 0, ok { ok = false; why = String(cString: strerror(errno)) }
        guard ok else {
            unlink(path)
            return .failed(why)
        }
        return .written
    }
}
