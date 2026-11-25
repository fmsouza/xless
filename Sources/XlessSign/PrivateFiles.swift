import Foundation
import XlessCore

/// The files rcodesign reads a key from: mode 0600, in a fresh directory of mode 0700 that is removed with everything in
/// it when the call ends, however it ends. Signing, the DMG, the flat package and notarization all take theirs from here;
/// nothing else writes key material for a tool.
public struct PrivateFiles {
    public let directory: URL
    let stage: Stage
    let parent: URL

    /// Runs `body` with a directory of its own under `parent` (the temporary directory).
    public static func with<T>(stage: Stage, in parent: URL = FileManager.default.temporaryDirectory, _ body: (PrivateFiles) throws -> T) throws -> T {
        let files = PrivateFiles(directory: parent.appendingPathComponent("xless-keys-\(UUID().uuidString)"), stage: stage, parent: parent)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            // Without intermediate directories: one that is already there is not ours.
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw files.cannotWrite }
        defer { try? FileManager.default.removeItem(at: files.directory) }
        return try body(files)
    }

    /// Writes `contents` to a new file of mode 0600.
    public func write(_ contents: Data, as name: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        do { try SigningKey.writeExclusively(contents, toPath: file.path, mode: 0o600) } catch { throw cannotWrite }
        return file
    }

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
