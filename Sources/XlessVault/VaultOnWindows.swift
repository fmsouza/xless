#if os(Windows)
import Foundation
import XlessCore

// The store's files on Windows, each as `PrivateFile` has it. The directory is held while anything in it is used.

extension VaultLocation {
    /// Whether there is anything of the store file's name (a link is not followed); what cannot be told counts as there.
    public var fileExists: Bool { PrivateFile.exists(file.path) }

    /// The directory, checked; false when it does not exist.
    func checkDirectory() throws -> Bool {
        try Self.mapping { try PrivateFile.inDirectory(directory.path, .builtInDrive) { true } ?? false }
    }

    /// Creates the directory and its missing parents, then checks it.
    func createDirectory() throws {
        try Self.mapping { try PrivateFile.makeDirectory(directory.path) }
        guard try checkDirectory() else {
            throw VaultError(.io, "cannot create \(directory.path)", fix: "check the parent directory's permissions")
        }
    }

    fileprivate static func mapping<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let refusal as PrivateFile.Refusal {
            switch refusal.kind {
            case .unsafe, .link, .notFile: throw VaultError(.unsafePath, refusal.cause, fix: refusal.fix)
            case .missing, .exists, .tooLarge, .failed: throw VaultError(.io, refusal.cause, fix: refusal.fix)
            }
        }
    }
}

extension VaultStore {
    /// The store, or nil when there is none yet. Its directory and file are checked first.
    public func read() throws -> VaultFile? {
        let data = try VaultLocation.mapping {
            try PrivateFile.inDirectory(location.directory.path, .builtInDrive) {
                try PrivateFile.read(location.file.path, .builtInDrive, limit: Self.maximumSize)
            }
        }
        guard let data = data ?? nil else { return nil }
        guard data.count <= Self.maximumSize else { throw VaultError.tampered("file larger than \(Self.maximumSize >> 20) MiB") }
        return try VaultFile.decode(data)
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let done = try VaultLocation.mapping {
            try PrivateFile.inDirectory(location.directory.path, .builtInDrive) {
                try PrivateFile.withLock(location.lockFile.path, .builtInDrive, body)
            }
        }
        guard let done else {
            throw VaultError(.io, "cannot open the lock file \(location.lockFile.path): there is no directory \(location.directory.path)", fix: "re-run")
        }
        return done
    }

    /// The atomic replace. Call with the lock held.
    func write(_ file: VaultFile) throws {
        let data = try file.encoded()
        let name = ".secrets.vault.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        let temporary = location.directory.appendingPathComponent(name).path
        let written: Void? = try VaultLocation.mapping {
            try PrivateFile.inDirectory(location.directory.path, .builtInDrive) {
                try PrivateFile.replace(location.file.path, with: data, through: temporary, .builtInDrive)
            }
        }
        guard written != nil else { throw VaultError(.io, "could not write \(location.file.path): its directory is gone", fix: "the store is unchanged: re-run") }
    }
}
#endif
