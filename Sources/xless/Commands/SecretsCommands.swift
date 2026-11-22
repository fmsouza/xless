import ArgumentParser
import Crypto
import Foundation
import XlessCore
import XlessSign
import XlessVault

extension VaultEntry.Kind: ExpressibleByArgument {}

struct SecretsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Keep Apple keys and passwords in an encrypted store, and let the pipeline read them from it.",
        discussion: """
        The store is $XDG_DATA_HOME/xless/vault/secrets.vault (else ~/.local/share/xless/vault/), each entry sealed with \
        AES-256-GCM under a data key wrapped by your passphrase (scrypt). The passphrase is read from the terminal only.

        The pipeline reads a secret from NAME, else NAME_FILE, else the store's entry NAME (or NAME@<suffix>, one per \
        team); CI keeps using the environment. ASC_KEY_ID and ASC_ISSUER_ID come from the ASC_KEY_P8 entry's IDs.
        Well-known names: ASC_KEY_P8, XLESS_DIST_KEY, XLESS_DEVID_KEY, XLESS_INSTALLER_KEY.
        """,
        subcommands: [SecretsInitCommand.self, SecretsStatusCommand.self, SecretsListCommand.self, SecretsImportCommand.self,
                      SecretsExportCommand.self, SecretsRmCommand.self, SecretsUnlockCommand.self, SecretsLockCommand.self,
                      SecretsPasswdCommand.self])
}

/// What the `secrets` commands share.
enum SecretStoreCLI {
    static var location: VaultLocation { .standard() }
    static var store: VaultStore { VaultStore(location: location) }
    static let cache = KernelKeyringCache()

    /// Runs a command's body hardened (`SecretScope`), any failure as a `[config] cause — fix` error.
    static func run<T>(_ body: () throws -> T) throws -> T {
        SecretScope.enter()
        do { return try body() } catch { throw XlessError.wrapping(error, stage: .config) }
    }

    static func existing() throws -> VaultFile {
        guard let file = try store.read() else { throw VaultStore.notInitialized(location) }
        return file
    }

    static func entry(_ name: String, in file: VaultFile) throws -> VaultEntry {
        guard let entry = file.entry(named: name) else {
            throw VaultError(.noEntry, "the secret store has no entry \(name)", fix: "see the names with `xless secrets list`")
        }
        return entry
    }

    /// The `--remember` duration, refused up front (before any passphrase) where there is no keyring to keep it in.
    static func remember(_ text: String?) throws -> Int? {
        guard let text else { return nil }
        let seconds = try RememberDuration.seconds(text)
        guard cache.isAvailable else {
            throw VaultError(.cacheUnavailable, "--remember needs the kernel keyring, which is not available here (macOS, or a container that blocks it)",
                             fix: "run without --remember; each command that needs the store asks the passphrase")
        }
        return seconds
    }

    static func unlock(_ file: VaultFile, remember: Int?, reason: String) throws -> SymmetricKey {
        try VaultUnlocker.dataKey(for: file, cache: cache, prompter: { try? TerminalPrompter.forSecretStore() }, remember: remember, reason: reason)
    }

    /// Fails if the store was replaced since `file` was read (the key in hand would not be its key).
    static func same(_ file: VaultFile, as unlocked: VaultFile) throws {
        guard file.id == unlocked.id else {
            throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command")
        }
    }

    /// Once a file's secret is in the store: asks (on a terminal) whether to delete the file; else says it is still there.
    static func offerToDelete(_ file: String) throws {
        if let terminal = try? TerminalPrompter.forSecretStore(),
           try terminal.confirm("The secret is in the store. Delete \(file) now?") {
            if unlink(file) == 0 { print("deleted \(file)") } else {
                say("warning: could not delete \(file): \(String(cString: strerror(errno)))")
            }
        } else {
            say("\(file) still holds the secret in clear; delete it once you no longer need it")
        }
    }

    static func say(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }
}

struct RememberOption: ParsableArguments {
    @Option(help: "Keep the store unlocked for this long in the kernel keyring (Linux), e.g. 30m; at most 1h. Off by default.")
    var remember: String?
}

struct SecretsInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init", abstract: "Create the secret store (asks a new passphrase twice).")
    @OptionGroup var options: RememberOption

    func run() throws {
        try SecretStoreCLI.run {
            let remember = try SecretStoreCLI.remember(options.remember)
            if try SecretStoreCLI.store.read() != nil || SecretStoreCLI.location.fileExists {
                throw VaultError(.alreadyInitialized, "a secret store already exists at \(SecretStoreCLI.location.file.path)",
                                 fix: "use it (`xless secrets status`), or change its passphrase with `xless secrets passwd`")
            }
            let terminal = try TerminalPrompter.forSecretStore()
            terminal.say("The passphrase protects every key in the store; there is no way to recover it. Choose a long one.")
            let passphrase = try VaultUnlocker.newPassphrase(terminal)
            let (file, key) = try VaultCrypto.newVault(passphrase: passphrase)
            try SecretStoreCLI.store.create(file)
            if let remember { try SecretStoreCLI.cache.store(id: file.id, key: VaultCrypto.keyBytes(key), seconds: remember) }
            print("created the secret store at \(SecretStoreCLI.location.file.path)")
        }
    }
}

struct SecretsStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Where the store is, how many entries it holds, whether it is unlocked (never a value).")

    func run() throws {
        try SecretStoreCLI.run {
            let file = try SecretStoreCLI.store.read()
            let cache = SecretStoreCLI.cache
            let unlocked: Bool? = file.flatMap { f in cache.isAvailable ? ((try? cache.load(id: f.id)) ?? nil) != nil : nil }
            print(VaultReport.status(location: SecretStoreCLI.location, file: file, unlocked: unlocked))
        }
    }
}

struct SecretsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the entries: names, kinds and IDs (never a value; no passphrase needed).")

    func run() throws {
        try SecretStoreCLI.run { print(VaultReport.list(try SecretStoreCLI.existing())) }
    }
}

struct SecretsImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Add a file's content (a .p8 or PEM key, a password) to the store; offers to delete the file afterwards.")

    @Argument(help: "Entry name: ASC_KEY_P8, XLESS_DIST_KEY, XLESS_DEVID_KEY, XLESS_INSTALLER_KEY (optionally @<TEAM_ID>), or your own.")
    var name: String
    @Option(help: "The file to import.") var file: String
    @Option(help: "asc-api-key, signing-key, auth-key, password or generic (default: from the name).") var kind: VaultEntry.Kind?
    @Option(help: "Apple team ID the secret belongs to.") var teamId: String?
    @Option(help: "Key ID (asc-api-key, auth-key; default: from an AuthKey_<KEY_ID>.p8 file name).") var keyId: String?
    @Option(help: "App Store Connect issuer ID (required for asc-api-key).") var issuerId: String?
    @Option(help: "Certificate ID (signing-key).") var certificateId: String?
    @Option(help: "Expiry date, YYYY-MM-DD.") var expires: String?
    @OptionGroup var options: RememberOption

    func run() throws {
        try SecretStoreCLI.run {
            guard VaultEntry.isValidName(name) else {
                throw VaultError(.invalidName, "\(name) is not a valid entry name", fix: "use letters, digits and . _ @ - (e.g. XLESS_DIST_KEY@ABCDE12345)")
            }
            let kind = kind ?? VaultImport.inferredKind(for: name)
            let remember = try SecretStoreCLI.remember(options.remember)
            let metadata = VaultEntry.Metadata(
                teamID: teamId, keyID: keyId ?? (kind == .ascAPIKey || kind == .authKey ? VaultImport.keyID(fromFileName: URL(fileURLWithPath: file).lastPathComponent) : nil),
                issuerID: issuerId, certificateID: certificateId, created: Date(), expires: try expires.map(Self.day))
            if kind == .ascAPIKey, metadata.keyID == nil || metadata.issuerID == nil {
                throw VaultError(.invalidInput, "an App Store Connect API key needs its key ID and issuer ID",
                                 fix: "pass --issuer-id (App Store Connect > Users and Access > Integrations) and --key-id unless the file is AuthKey_<KEY_ID>.p8")
            }
            let secret = try Self.readFile(file)
            try VaultImport.validate(secret, kind: kind)
            let current = try SecretStoreCLI.existing()
            if current.entry(named: name) != nil { throw Self.exists(name) }
            let key = try SecretStoreCLI.unlock(current, remember: remember, reason: "importing \(name)")
            try SecretStoreCLI.store.update { file in
                try SecretStoreCLI.same(file, as: current)
                if file.entry(named: name) != nil { throw Self.exists(name) }
                var next = file
                next.entries.append(try VaultCrypto.seal(name: name, kind: kind, metadata: metadata, secret: secret, dataKey: key))
                return next
            }
            secret.wipe()
            print("imported \(name) (\(kind.rawValue)) into the secret store")
            try SecretStoreCLI.offerToDelete(file)
        }
    }

    static func exists(_ name: String) -> VaultError {
        VaultError(.entryExists, "the secret store already has an entry \(name)", fix: "remove it first (`xless secrets rm \(name)`) or choose another name")
    }

    static func day(_ text: String) throws -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: text) else { throw VaultError(.invalidInput, "--expires \(text) is not a date", fix: "use YYYY-MM-DD") }
        return d
    }

    /// The file's bytes straight into a `SecretBytes` (a regular file of at most 1 MiB).
    static func readFile(_ path: String) throws -> SecretBytes {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw VaultError(.io, "cannot open \(path): \(String(cString: strerror(errno)))", fix: "check the path given to --file") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw VaultError(.io, "\(path) is not a regular file", fix: "check the path given to --file")
        }
        let size = Int(st.st_size)
        guard size <= 1 << 20 else { throw VaultError(.invalidSecret, "\(path) is larger than 1 MiB", fix: "import a key or a password, not a bundle") }
        let bytes = SecretBytes(count: size)
        var off = 0
        while off < size {
            let n = bytes.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress! + off, size - off) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw VaultError(.io, "cannot read \(path)", fix: "check the file") }
            off += n
        }
        return bytes
    }
}

struct SecretsExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Write an entry's secret to a new file (mode 0600, never overwriting); the copy is in clear.")
    @Argument(help: "Entry name (see `xless secrets list`).") var name: String
    @Option(help: "The file to create; must not exist.") var out: String
    @OptionGroup var options: RememberOption

    func run() throws {
        try SecretStoreCLI.run {
            let remember = try SecretStoreCLI.remember(options.remember)
            let file = try SecretStoreCLI.existing()
            let entry = try SecretStoreCLI.entry(name, in: file)
            let secret = try VaultCrypto.open(entry, dataKey: try SecretStoreCLI.unlock(file, remember: remember, reason: "exporting \(name)"))
            var data = secret.withUnsafeBytes { Data($0) }
            defer {
                data.withUnsafeMutableBytes { SecretBytes.zero($0) }
                secret.wipe()
            }
            do { try SigningKey.writeExclusively(data, toPath: out, mode: 0o600) } catch let e as XlessError {
                throw XlessError(.config, e.cause, fix: e.fix)
            }
            print("wrote \(name) to \(out)")
            SecretStoreCLI.say("warning: \(out) holds the secret in clear (mode 0600); delete it as soon as it has served")
        }
    }
}

struct SecretsRmCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an entry from the store (asks first). It cannot be recovered.")
    @Argument(help: "Entry name (see `xless secrets list`).") var name: String
    @OptionGroup var confirmation: YesOption

    func run() throws {
        try SecretStoreCLI.run {
            let file = try SecretStoreCLI.existing()
            _ = try SecretStoreCLI.entry(name, in: file)
            guard try AccountConfirm.confirm("Remove \(name) from the secret store? It cannot be recovered.", action: "removing \(name)",
                                             yes: confirmation.yes, stage: .config, terminal: { try? TerminalPrompter.forSecretStore() }) else {
                print("kept \(name)")
                return
            }
            try SecretStoreCLI.store.update { current in
                var next = current
                next.entries.removeAll { $0.name == name }
                guard next.entries.count < current.entries.count else { throw VaultError(.noEntry, "the secret store has no entry \(name)", fix: "see `xless secrets list`") }
                return next
            }
            print("removed \(name) from the secret store")
        }
    }
}

struct SecretsUnlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock", abstract: "Keep the store unlocked for a while in the kernel keyring (Linux), so later commands of this session need no passphrase.")
    @Option(help: "How long, e.g. 30m; at most 1h.") var remember: String

    func run() throws {
        try SecretStoreCLI.run {
            let seconds = try SecretStoreCLI.remember(remember) ?? 0
            let file = try SecretStoreCLI.existing()
            _ = try SecretStoreCLI.unlock(file, remember: seconds, reason: "unlocking")
            print("the secret store stays unlocked for \(seconds / 60 > 0 ? "\(seconds / 60) min" : "\(seconds) s") (until `xless secrets lock`)")
        }
    }
}

struct SecretsLockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "Forget a remembered unlock now.")

    func run() throws {
        try SecretStoreCLI.run {
            let file = try SecretStoreCLI.existing()
            print(try SecretStoreCLI.cache.forget(id: file.id) ? "locked the secret store" : "the secret store was not unlocked")
        }
    }
}

struct SecretsPasswdCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "passwd",
        abstract: "Change the store's passphrase.",
        discussion: "Re-wraps the data key; the entries are not re-encrypted, so a copy of the old file still opens with the old passphrase.")

    func run() throws {
        try SecretStoreCLI.run {
            let file = try SecretStoreCLI.existing()
            let terminal = try TerminalPrompter.forSecretStore()
            // Always the current passphrase, even when a remembered unlock is there.
            let key = try VaultUnlocker.dataKey(for: file, cache: nil, prompter: { terminal }, reason: "changing the passphrase")
            let passphrase = try VaultUnlocker.newPassphrase(terminal)
            try SecretStoreCLI.store.update { current in
                try SecretStoreCLI.same(current, as: file)
                return try VaultCrypto.rewrap(current, dataKey: key, passphrase: passphrase)
            }
            print("changed the secret store's passphrase")
        }
    }
}
