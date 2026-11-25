import ArgumentParser
import Crypto
import Foundation
import XlessAgent
import XlessCore
import XlessAppleID
import XlessSign
import XlessVault

/// What `--kind` takes: what people keep, not what xless saves itself.
extension VaultEntry.Kind: ExpressibleByArgument {
    static var arguments: [Self] { allCases.filter { $0 != .appleSession } }
    public static var allValueStrings: [String] { arguments.map(\.rawValue) }

    public init?(argument: String) {
        guard let kind = Self.arguments.first(where: { $0.rawValue == argument }) else { return nil }
        self = kind
    }
}

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

        With `secrets: { backend: helper, helper: <name> }` in ~/.config/xless/config.yml, an external credential \
        helper (xless-credential-<name> on PATH: your desktop keyring through secret-tool, pass, …) holds the secrets \
        instead, and these commands work on it the same way (docs/secrets.md).
        """,
        subcommands: [SecretsInitCommand.self, SecretsStatusCommand.self, SecretsListCommand.self, SecretsImportCommand.self,
                      SecretsExportCommand.self, SecretsRmCommand.self, SecretsUnlockCommand.self, SecretsLockCommand.self,
                      SecretsPasswdCommand.self, SecretsMaterializeCommand.self, SecretsNamedByCommand.self, SecretsRedactCommand.self])
}

/// What the `secrets` commands share.
enum SecretStoreCLI {
    static let cache = HeldKeyCache()

    /// The store config.yml's `secrets.backend` names, made once per process and shared by every command and by the
    /// pipeline's lookups (`main`), so the vault's passphrase is asked at most once.
    private static let configured = Result { try ConfiguredSecretStore.load(cache: cache, manner: KeepOffer.shared, prompter: { try? TerminalPrompter.forSecretStore() }) }

    static func backend() throws -> ConfiguredSecretStore { try configured.get() }

    /// The configured store (the vault, or the credential helper).
    static func store() throws -> any SecretStore { try backend().store }

    /// That this terminal has the vault unlocked, without asking for anything; nil when it has not.
    static func witness() -> AgentWitness? {
        guard case .success(.vault(let vault)) = configured else { return nil }
        return witness(of: vault)
    }

    static func witness(of vault: VaultSecretStore) -> AgentWitness? {
        guard let file = (try? vault.vault.read()) ?? nil, let key = vault.heldKey(for: file, using: false) else { return nil }
        return AgentWitness(item: HeldSecrets.name(ofVault: file.id), key: VaultCrypto.keyBytes(key))
    }

    /// Drops the vault's data key this process unlocked (`VaultSecretStore.forget`): `main` calls it before exiting.
    static func forgetUnlock() {
        if case .success(.vault(let vault)) = configured { vault.forget() }
    }

    /// The secret-store fallback `main` installs: the configured store, or (config.yml is wrong, the helper is missing)
    /// one that reports why whenever a secret is looked up in it.
    static var fallback: any SecretFallback {
        switch configured {
        case .success(let configured): VaultResolver(secrets: configured.store)
        case .failure(let error): UnavailableStore(error: error)
        }
    }

    /// What the vault-only commands (`passwd`) say with a credential helper.
    static func vaultOnly(_ what: String, helper: HelperSecretStore) -> VaultError {
        VaultError(.unsupportedByBackend, "\(what) is for the encrypted vault; the secrets are kept by \(helper.place) (secrets.backend in \(UserConfig.file().path))",
                   fix: "use the keyring's or the password manager's own tools for its password")
    }

    /// Runs a command's body hardened (`SecretScope`), any failure as a `[config] cause — fix` error.
    static func run<T>(_ body: () throws -> T) throws -> T {
        SecretScope.enter()
        do { return try body() } catch { throw XlessError.wrapping(error, stage: .config) }
    }

    /// The vault's file; an error when there is none.
    static func existing(_ vault: VaultSecretStore) throws -> VaultFile {
        guard let file = try vault.vault.read() else { throw VaultStore.notInitialized(vault.vault.location) }
        return file
    }

    static func entry(_ name: String, in file: some SecretEntries) throws -> VaultEntry {
        guard let entry = file.entry(named: name) else {
            throw VaultError(.noEntry, "the secret store has no entry \(name)", fix: "see the names with `xless secrets list`")
        }
        return entry
    }

    /// The `--remember` hold, refused up front (before any passphrase) where there is nothing to keep it in.
    static func remember(_ text: String?) throws -> SecretHold? {
        guard let text else { return nil }
        if case .helper = try backend() {
            say("note: --remember is for the encrypted vault; the credential helper keeps its own lock")
            return nil
        }
        let hold = try HeldSecrets.settings.get().hold(text, option: "--remember", stage: .config)
        try cache.require(hold)
        return hold
    }

    /// Unlocks the vault and keeps it unlocked for `hold`; what to say about it.
    static func unlock(_ vault: VaultSecretStore, hold: SecretHold) throws -> String {
        let file = try existing(vault)
        let renewed = cache.held(id: file.id) != nil
        _ = try vault.key(for: file, remember: hold, reason: "unlocking")
        guard let held = cache.held(id: file.id) else {
            throw VaultError(.cacheUnavailable, "the store did not stay unlocked", fix: "run `xless lock`, then `xless unlock`")
        }
        if !renewed, AppleWebCLI.held.held() == nil, let terminal = try? TerminalPrompter.forSecretStore() { KeepOffer.shared.also(.session, terminal) }
        return "the secret store stays unlocked \(VaultReport.held(held, now: Date())) (until `xless lock`)"
    }

    /// There is nothing to keep unlocked: no vault, or it is already.
    static var isHeldOrAbsent: Bool {
        guard case .success(.vault(let vault)) = configured, let file = (try? vault.vault.read()) ?? nil else { return true }
        return cache.held(id: file.id) != nil
    }

    /// Fails if the store was replaced since `file` was read (the key in hand would not be its key).
    static func same(_ file: SecretCatalog, as unlocked: SecretCatalog) throws {
        guard file.id == unlocked.id else {
            throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command")
        }
    }

    /// Once a file's secret is in the store: asks (on a terminal) whether to delete the file; else says it is still there.
    static func offerToDelete(_ file: String) throws {
        if !InputGate.isOff, let terminal = try? TerminalPrompter.forSecretStore(),
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
    @Option(help: ArgumentHelp("Keep the store unlocked for later commands of this terminal (see `xless unlock`), for this long (e.g. 30m, 8h) or, without a duration, as long as config.yml's `unlock` says. Off by default.", valueName: "duration"))
    var remember: String?
}

struct SecretsInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init", abstract: "Create the secret store (asks a new passphrase twice).")
    @OptionGroup var options: RememberOption

    func run() throws {
        try SecretStoreCLI.run {
            let vault: VaultSecretStore
            switch try SecretStoreCLI.backend() {
            case .helper(let helper):
                let count = try helper.existingCatalog().entries.count
                print("\(helper.place) answers and holds \(count) xless entr\(count == 1 ? "y" : "ies"); there is no store to create (secrets.backend is helper)")
                return
            case .vault(let v): vault = v
            }
            let remember = try SecretStoreCLI.remember(options.remember)
            let location = vault.vault.location
            if try vault.vault.read() != nil || location.fileExists {
                throw VaultError(.alreadyInitialized, "a secret store already exists at \(location.file.path)",
                                 fix: "use it (`xless secrets status`), or change its passphrase with `xless secrets passwd`")
            }
            let terminal = try TerminalPrompter.forSecretStore()
            terminal.say("The passphrase protects every key in the store; there is no way to recover it. Choose a long one.")
            let passphrase = try VaultUnlocker.newPassphrase(terminal)
            let (file, key) = try VaultCrypto.newVault(passphrase: passphrase)
            try vault.vault.create(file)
            // An unlock of a store that was here before opens nothing any more.
            do { try SecretStoreCLI.cache.forget(place: location.file.path) } catch { SecretStoreCLI.say("warning: \(error)") }
            print("created the secret store at \(location.file.path)")
            func keep(_ hold: SecretHold) throws {
                try SecretStoreCLI.cache.store(VaultCrypto.keyBytes(key), id: file.id, place: location.file.path, hold: hold, typedAgo: 0)
            }
            if let remember {
                try keep(remember)
            } else if let hold = KeepOffer.shared.offer(terminal) {
                do {
                    try keep(hold)
                    KeepOffer.shared.kept(true, terminal)
                } catch {
                    KeepOffer.shared.kept(false, terminal)
                    terminal.say("note: the store is not kept unlocked: \(error)")
                }
            }
        }
    }
}

struct SecretsStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Where the store is, how many entries it holds, whether it is unlocked (never a value).")

    func run() throws {
        try SecretStoreCLI.run {
            switch try SecretStoreCLI.backend() {
            case .helper(let helper):
                print(VaultReport.status(helper: helper, catalog: try helper.existingCatalog()))
            case .vault(let vault):
                let file = try vault.vault.read()
                let cache = SecretStoreCLI.cache
                print(VaultReport.status(location: vault.vault.location, file: file, held: file.flatMap { cache.held(id: $0.id) }, canHold: cache.isAvailable))
            }
        }
    }
}

struct SecretsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the entries: names, kinds and IDs (never a value; no passphrase needed).")

    func run() throws {
        try SecretStoreCLI.run { print(VaultReport.list(try SecretStoreCLI.store().existingCatalog())) }
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
    @Option(help: ArgumentHelp("The API key's role(s), comma-separated (asc-api-key; shown by `xless auth status`).", valueName: "roles")) var role: String?
    @Option(help: ArgumentHelp("The auth key's services, comma-separated: \(AuthKeyServiceArgument.names) (auth-key).", valueName: "services")) var services: String?
    @OptionGroup var options: RememberOption

    func validate() throws {
        let kind = kind ?? VaultImport.inferredKind(for: name)
        if let role {
            guard kind == .ascAPIKey else { throw ValidationError("--role is an App Store Connect API key's (--kind asc-api-key)") }
            guard !role.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError("--role is empty") }
            do { _ = try APIKeyRoles.parse(role.split(separator: ",").map(String.init)) } catch let e as XlessError { throw ValidationError("\(e.cause); \(e.fix)") }
        }
        if let services {
            guard kind == .authKey else { throw ValidationError("--services is an auth key's (--kind auth-key)") }
            guard services.split(separator: ",").allSatisfy({ AuthKeyService(argument: $0.trimmingCharacters(in: .whitespaces)) != nil }),
                  !services.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError("--services \(services) is not a list of auth key services: use \(AuthKeyServiceArgument.names), comma-separated")
            }
        }
    }

    func run() throws {
        try SecretStoreCLI.run {
            guard VaultEntry.isValidName(name) else {
                throw VaultError(.invalidName, "\(name) is not a valid entry name", fix: "use letters, digits and . _ @ - (e.g. XLESS_DIST_KEY@ABCDE12345)")
            }
            let kind = kind ?? VaultImport.inferredKind(for: name)
            try VaultEntry.requireAllowed(name: name, kind: kind)
            let remember = try SecretStoreCLI.remember(options.remember)
            let metadata = VaultEntry.Metadata(
                teamID: teamId, keyID: keyId ?? (kind == .ascAPIKey || kind == .authKey ? VaultImport.keyID(fromFileName: URL(fileURLWithPath: file).lastPathComponent) : nil),
                issuerID: issuerId, certificateID: certificateId, created: Date(), expires: try expires.map(Self.day),
                role: try role.map { APIKeyRoles.recorded(try APIKeyRoles.parse($0.split(separator: ",").map(String.init))) } ?? nil,
                services: try services.map { AuthKeyStore.recorded(try AuthKeyServiceArgument.parse([$0])) })
            if kind == .ascAPIKey, metadata.keyID == nil || metadata.issuerID == nil {
                throw VaultError(.invalidInput, "an App Store Connect API key needs its key ID and issuer ID",
                                 fix: "pass --issuer-id (App Store Connect > Users and Access > Integrations) and --key-id unless the file is AuthKey_<KEY_ID>.p8")
            }
            let secret = try Self.readFile(file)
            try VaultImport.validate(secret, kind: kind)
            let store = try SecretStoreCLI.store()
            let current = try store.existingCatalog()
            if current.entry(named: name) != nil { throw Self.exists(name) }
            try current.requireWritable()
            try store.unlock(current, remember: remember, reason: "importing \(name)")
            try store.update(reason: "importing \(name)") { file in
                try SecretStoreCLI.same(file, as: current)
                if file.entry(named: name) != nil { throw Self.exists(name) }
                return [.add(name: name, kind: kind, metadata: metadata, secret: secret)]
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
            let store = try SecretStoreCLI.store()
            let file = try store.existingCatalog()
            let entry = try SecretStoreCLI.entry(name, in: file)
            try Self.refuseSession(entry)
            try store.unlock(file, remember: remember, reason: "exporting \(name)")
            let secret = try store.secret(entry, in: file, reason: "exporting \(name)")
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

    static func refuseSession(_ entry: VaultEntry) throws {
        guard entry.kind == .appleSession else { return }
        throw XlessError(.config, "\(entry.name) is xless's own (an Apple ID session): it is never written in clear", fix: "remove it with `xless auth logout`")
    }
}

struct SecretsRmCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an entry from the store (asks first). It cannot be recovered.")
    @Argument(help: "Entry name (see `xless secrets list`).") var name: String
    @OptionGroup var confirmation: YesOption

    func run() throws {
        try SecretStoreCLI.run {
            let store = try SecretStoreCLI.store()
            let catalog = try store.existingCatalog()
            _ = try SecretStoreCLI.entry(name, in: catalog)
            try catalog.requireWritable()
            guard try AccountConfirm.confirm("Remove \(name) from the secret store? It cannot be recovered.", action: "removing \(name)",
                                             yes: confirmation.yes, stage: .config, terminal: { try? TerminalPrompter.forSecretStore() }) else {
                print("kept \(name)")
                return
            }
            try store.update(reason: "removing \(name)") { current in
                guard current.entry(named: name) != nil else { throw VaultError(.noEntry, "the secret store has no entry \(name)", fix: "see `xless secrets list`") }
                return [.remove(name: name)]
            }
            print("removed \(name) from the secret store")
        }
    }
}

struct SecretsUnlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock", abstract: "Keep the store unlocked for a while, so later commands of this terminal need no passphrase (the same as `xless unlock`).")
    @Option(help: ArgumentHelp("How long, e.g. 30m or 8h; without a duration, as long as config.yml's `unlock` says.", valueName: "duration")) var remember: String

    func run() throws {
        try SecretStoreCLI.run {
            guard case .vault(let vault) = try SecretStoreCLI.backend() else {
                print("the credential helper keeps its own lock (unlock your keyring or agent with its own tools); nothing to do")
                return
            }
            guard let hold = try SecretStoreCLI.remember(remember) else { return }
            print(try SecretStoreCLI.unlock(vault, hold: hold))
        }
    }
}

struct SecretsLockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "Forget the store's unlock now, and a yes to keeping the next one (`xless lock` also drops a kept Apple ID session).")

    func run() throws {
        try SecretStoreCLI.run {
            guard case .vault(let vault) = try SecretStoreCLI.backend() else {
                print("the credential helper keeps its own lock (lock your keyring or agent with its own tools); nothing to do")
                return
            }
            let file = try SecretStoreCLI.existing(vault)
            KeepOffer.shared.withdraw()
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
            let vault: VaultSecretStore
            switch try SecretStoreCLI.backend() {
            case .helper(let helper): throw SecretStoreCLI.vaultOnly("`xless secrets passwd`", helper: helper)
            case .vault(let v): vault = v
            }
            let file = try SecretStoreCLI.existing(vault)
            try file.requireWritable()
            let terminal = try TerminalPrompter.forSecretStore()
            // Always the current passphrase, even when a remembered unlock is there.
            let key = try VaultUnlocker.dataKey(for: file, cache: nil, prompter: { terminal }, reason: "changing the passphrase")
            let passphrase = try VaultUnlocker.newPassphrase(terminal)
            try vault.vault.update { current in
                guard current.id == file.id else { throw VaultError(.io, "the secret store was replaced while this command ran", fix: "re-run the command") }
                return try VaultCrypto.rewrap(try VaultCrypto.upgrade(current, dataKey: key), dataKey: key, passphrase: passphrase)
            }
            // An unlock the old passphrase gave does not outlive it.
            let forgotten = Result { try SecretStoreCLI.cache.forget(id: file.id) }
            print("changed the secret store's passphrase")
            _ = try forgotten.get()
        }
    }
}

/// `xless secrets materialize`: plumbing for scripts/testflight.sh (`xless run`), not shown in the help. Writes the
/// store's secrets a run's containers need, once (one passphrase), into a fresh run directory on a tmpfs, one
/// sub-directory per container; the script mounts each into its container only and removes them.
struct SecretsMaterializeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "materialize",
        abstract: "Write the secrets a run's containers need from the store to a fresh tmpfs directory (used by xless run).",
        discussion: """
        Each SET=NAME[,NAME…] becomes <run dir>/SET/NAME (directories 0700, files 0600) under $XDG_RUNTIME_DIR/xless/; \
        ASC_KEY_ID and ASC_ISSUER_ID are the ASC_KEY_P8 entry's IDs. The run directory is printed on stdout as soon as \
        it exists. With no XDG_RUNTIME_DIR, or one that is not a tmpfs, it refuses unless --allow-disk \
        (then ~/.cache/xless/secrets/). --check only checks that the store holds every secret (no passphrase, nothing written), \
        and prints the optional ones (?NAME: written when the store has them) it holds.
        """,
        shouldDisplay: false)

    @Argument(help: "SET=NAME[,NAME…] (?NAME: optional), e.g. sign=ASC_KEY_P8,ASC_KEY_ID,ASC_ISSUER_ID,XLESS_DIST_KEY,?XLESS_DEMO_PASSWORD.") var sets: [String]
    @Option(help: "Prefer this team's entries (default: the saved team, `xless team use`).") var team: String?
    /// (testflight.sh's --allow-disk-secrets; named so argv's secret lint has nothing to object to)
    @Flag(help: "Accept a directory on disk when there is no tmpfs (XDG_RUNTIME_DIR).") var allowDisk = false
    @Flag(help: "Only check that the store holds every secret; write nothing, ask no passphrase.") var check = false

    func run() throws {
        try SecretStoreCLI.run {
            let parsed = try sets.map(MaterializeSet.parse)
            let team = team ?? AccountSession.savedTeam()
            if let team, team.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
                throw XlessError(.config, "--team \(team) is not a 10-character Apple team ID", fix: "copy it from `xless team list`")
            }
            let materializer = VaultMaterializer(secrets: try SecretStoreCLI.store(), team: team)
            // --check prints the optional (?NAME) secrets the store has, one per line
            if check { return try materializer.check(parsed).forEach { print($0) } }
            let base = try SecretRunBase.choose(allowDisk: allowDisk)
            // Unbuffered: the script reads this line even when the command is stopped half-way.
            _ = try materializer.write(parsed, base: base) { FileHandle.standardOutput.write(Data("\($0.path)\n".utf8)) }
        }
    }
}

struct SecretsRedactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redact",
        abstract: "Copy standard input to standard output with secrets replaced by <redacted> (used by scripts/acceptance-m7.sh).",
        discussion: """
        The rules of --verbose traces, applied to any text: PEM private key blocks, JWTs and bearer tokens, the values of \
        secret header lines (Cookie, Authorization, scnt…), of secret JSON fields and name=value pairs (passwords, \
        tokens, keys, sessions, the secret variables but their _FILE forms) and the query strings of URLs outside the \
        App Store Connect API. --hide-env NAME also hides the value of the environment variable NAME (an Apple ID, say) \
        wherever it appears. It reads no secret store and contacts nothing.
        """,
        shouldDisplay: false)

    @Option(name: .customLong("hide-env"), help: ArgumentHelp("Also hide the value of this environment variable (repeatable).", valueName: "name"))
    var hideEnvName: [String] = []

    func run() throws {
        let env = ProcessInfo.processInfo.environment
        let hidden = hideEnvName.compactMap { env[$0] }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: input, as: UTF8.self)
        FileHandle.standardOutput.write(Data(TextRedaction.redact(text, hiding: hidden).utf8))
    }
}

struct SecretsNamedByCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "named-by",
        abstract: "Print the secrets a run's upload reads under names its configuration gives, one per line (used by xless run).",
        discussion: """
        The TestFlight demo account's password: testflight.external.review.demoAccount's passwordSecret \
        (XLESS_DEMO_PASSWORD by default), when the demo account may need its password sent. Nothing when it never does. \
        The configuration is only parsed: no tool runs, and the secret store is not opened.
        """,
        shouldDisplay: false)

    @Option(help: "An overlay file (Tauri, cargo or React Native).") var config: String?
    @Option(help: "A project directory (its xless.yml).") var project: String?
    @Option(help: "The platform the run ships (ios or macos).") var platform: Platform = .ios

    func validate() throws {
        guard (config == nil) != (project == nil) else { throw ValidationError("give --config <overlay> or --project <dir>") }
    }

    func run() throws {
        let file = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL }
        for name in try RunSecretNames.upload(config: config.map(file), project: project.map(file), platform: platform) { print(name) }
    }
}

/// The secret-store fallback when the configured store cannot be used: each lookup that reaches it fails with why.
struct UnavailableStore: SecretFallback {
    let error: any Error

    func lookup(_ name: String, stage: Stage) throws -> String? {
        let e = XlessError.wrapping(error, stage: stage)
        throw XlessError(stage, "\(name) is not in the environment, and the secret store cannot be used: \(e.cause)", fix: e.fix)
    }
}
