import CXlessProcess
import Foundation
import XlessCore

/// The files rcodesign reads a key from: mode 0600, in a fresh directory of mode 0700 that is removed with everything in
/// it when the call ends, however it ends, or a signal ends xless meanwhile (any that can be caught: SIGKILL cannot). The
/// directory is made with that mode (mkdir(2)), never opened up first, and every file in it is created by this type
/// (`O_CREAT|O_EXCL|O_NOFOLLOW`), the one a tool then writes into included. Signing, the DMG, the flat package and
/// notarization all take theirs from here; nothing else writes key material for a tool.
public struct PrivateFiles {
    public let directory: URL
    let stage: Stage
    let parent: URL
    private let ended = RemovedWhenEnded()

    /// Runs `body` with a directory of its own under `parent` (the temporary directory).
    public static func with<T>(stage: Stage, in parent: URL = FileManager.default.temporaryDirectory, _ body: (PrivateFiles) throws -> T) throws -> T {
        let files = PrivateFiles(directory: parent.appendingPathComponent("xless-keys-\(UUID().uuidString)"), stage: stage, parent: parent)
        defer { files.ended.forget() }
        guard files.ended.add(files.directory, isDirectory: true) else { throw files.cannotWrite }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch { throw files.cannotWrite }
        // Not Foundation's, which makes the directory open and then sets its mode. One that is already there is not ours.
        guard mkdir(files.directory.path, 0o700) == 0 else { throw files.cannotWrite }
        defer { try? FileManager.default.removeItem(at: files.directory) }
        return try body(files)
    }

    /// Writes `contents` to a new file of mode 0600.
    public func write(_ contents: Data, as name: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        guard ended.add(file) else { throw cannotWrite }
        do { try SigningKey.writeExclusively(contents, toPath: file.path, mode: 0o600) } catch { throw cannotWrite }
        return file
    }

    /// Writes `plist`, as XML, to a new file of mode 0600.
    public func write(plist: [String: Any], as name: String) throws -> URL {
        try write(Plist.data(plist, format: .xml, named: name, stage: stage), as: name)
    }

    /// A new, empty file of mode 0600 for a tool to write into.
    public func make(_ name: String) throws -> URL { try write(Data(), as: name) }

    /// The two PEM files `rcodesign sign` takes: the private key and its certificate.
    public func signer(key: SigningKey, certificate der: Data) throws -> (key: URL, certificate: URL) {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return (try write(Data(key.pem.utf8), as: "key.pem"),
                try write(Data("-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n".utf8), as: "cert.pem"))
    }

    private var cannotWrite: XlessError {
        XlessError(stage, "cannot write temporary key files", fix: "check free space and permissions of \(parent.path)")
    }
}

/// The paths that a signal which ends xless removes first (`xless_remove_when_ended`).
private final class RemovedWhenEnded: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UnsafeMutableRawPointer] = []

    /// Before it is there. False: it would not be removed.
    func add(_ url: URL, isDirectory: Bool = false) -> Bool {
        guard let entry = xless_remove_when_ended(url.path, isDirectory ? 1 : 0) else { return false }
        lock.withLock { entries.append(entry) }
        return true
    }

    func forget() {
        lock.withLock {
            for entry in entries { xless_keep_when_ended(entry) }
            entries = []
        }
    }
}
