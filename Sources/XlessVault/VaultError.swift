import XlessCore

/// A secret store failure. Its text names paths, entry names and what to do, never a secret's value or the passphrase.
public struct VaultError: Error, StageReportableError, CustomStringConvertible, Sendable {
    public enum Kind: Sendable, Equatable {
        case notInitialized, alreadyInitialized, wrongPassphrase, tampered, unsupported, unsafePath, io
        case entryExists, noEntry, invalidName, ambiguous, locked, invalidSecret, invalidInput, cacheUnavailable
    }

    public let kind: Kind
    public let cause: String
    public let fix: String

    public init(_ kind: Kind, _ cause: String, fix: String) {
        self.kind = kind
        self.cause = cause
        self.fix = fix
    }

    public var description: String { "\(cause) — \(fix)" }

    public func stageError(_ stage: Stage) -> XlessError { XlessError(stage, cause, fix: fix) }

    static func tampered(_ what: String) -> VaultError {
        VaultError(.tampered, "the secret store failed its integrity check (\(what)): it was altered or is corrupt; nothing was read from it",
                   fix: "restore secrets.vault from a backup, or move it aside and run `xless secrets init` and import the keys again")
    }

    static let wrongPassphrase = VaultError(.wrongPassphrase, "wrong passphrase for the secret store",
                                            fix: "re-run and type the passphrase given to `xless secrets init` (or the last `xless secrets passwd`)")
}
