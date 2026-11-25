import ArgumentParser
import Foundation
import XlessCore
import XlessRun
import XlessVault

/// What `secrets import-env` takes from a testflight.env: the secrets `xless run` reads from there, as entries of the store.
struct EnvImport {
    enum Source: Equatable {
        case file(String)
        case value(String)
    }

    struct Item: Equatable {
        /// The secret's variable, without `_FILE`.
        let base: String
        let source: Source
        var keyID: String?
        var issuerID: String?
    }

    var items: [Item] = []
    /// The variables that the store's entries stand for, and the others.
    var moved: [String] = [], left: [String] = []

    static let secrets = ["ASC_KEY_P8", "XLESS_DIST_KEY", "XLESS_DEVID_KEY", "XLESS_INSTALLER_KEY", "XLESS_DEMO_PASSWORD"]

    /// - Parameter read: a file's text (an ID's: not a secret).
    init(_ assignments: [(name: String, value: String)], read: (String) throws -> String) throws {
        var values: [String: String] = [:], names: [String] = []
        for (name, value) in assignments {
            if values[name] == nil { names.append(name) }
            values[name] = value
        }
        func given(_ name: String) -> String? { values[name].flatMap { $0.isEmpty ? nil : $0 } }
        for base in Self.secrets {
            guard let source = given("\(base)_FILE").map(Source.file) ?? given(base).map(Source.value) else { continue }
            var item = Item(base: base, source: source)
            moved += [base, "\(base)_FILE"]
            if base == "ASC_KEY_P8" {
                func id(_ name: String) throws -> String? {
                    moved += [name, "\(name)_FILE"]
                    let text = try given("\(name)_FILE").map(read) ?? given(name)
                    return text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                }
                item.keyID = try id("ASC_KEY_ID")
                item.issuerID = try id("ASC_ISSUER_ID")
                if item.keyID == nil, case .file(let path) = source { item.keyID = VaultImport.keyID(fromFileName: URL(fileURLWithPath: path).lastPathComponent) }
                guard item.keyID != nil, item.issuerID != nil else {
                    throw VaultError(.invalidInput, "the file names an App Store Connect API key (\(base)), but not its \(item.keyID == nil ? "key ID (ASC_KEY_ID)" : "issuer ID (ASC_ISSUER_ID)")",
                                     fix: "add it to the file, or import the key by itself: xless secrets import \(base)")
                }
            }
            items.append(item)
        }
        left = names.filter { !moved.contains($0) }
        moved = names.filter(moved.contains)
    }
}

struct SecretsImportEnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-env", abstract: "Move the secrets a testflight.env names into the store.",
        discussion: """
        Reads the file as data (nothing in it is run) and imports what its variables name: the App Store Connect API key \
        with its IDs, the three signing keys and the TestFlight demo account's password, each from its _FILE (or the value \
        itself), as one `xless secrets import` each would, with one passphrase. An entry the store has already is left as it \
        is. The file is not changed: the command says which of its lines have done their work.

        Put your team in xless.yml (teamID); xless run then needs no testflight.env (docs/secrets.md#moving-from-testflightenv).
        """)

    @Argument(help: "The file (default: $XLESS_TESTFLIGHT_ENV, else ~/.config/xless/testflight.env).") var file: String?
    @Option(help: "Apple team ID the secrets belong to: the entries are named NAME@<TEAM_ID>.") var teamId: String?
    @OptionGroup var options: RememberOption

    func validate() throws {
        if let teamId, teamId.wholeMatch(of: /[A-Z0-9]{10}/) == nil { throw ValidationError("--team-id \(teamId) is not a team ID (10 capital letters and digits)") }
    }

    func run() throws {
        try SecretStoreCLI.run {
            let environment = ProcessInfo.processInfo.environment
            let path = file ?? ProjectRun.environmentFile(environment)
            let text = try SecretsImportCommand.readFile(path)
            defer { text.wipe() }
            let plan: EnvImport
            do {
                plan = try EnvImport(EnvFile.parse(text.utf8String(), environment: environment)) { try SecretsImportCommand.readFile($0).utf8String() }
            } catch let problem as EnvFile.Problem {
                throw VaultError(.invalidInput, "\(path), line \(problem.line) \(problem.what)", fix: "keep only NAME=value lines in it: nothing in the file is run")
            }
            guard !plan.items.isEmpty else {
                throw VaultError(.invalidInput, "\(path) names no secret", fix: "nothing to move: see `xless secrets list`")
            }
            let remember = try SecretStoreCLI.remember(options.remember)
            let store = try SecretStoreCLI.store()
            let current = try store.existingCatalog()
            var new: [(name: String, kind: VaultEntry.Kind, metadata: VaultEntry.Metadata, secret: SecretBytes, item: EnvImport.Item)] = []
            defer { for entry in new { entry.secret.wipe() } }
            for item in plan.items {
                let name = CertificateKeyStore.entryName(base: item.base, team: teamId), kind = VaultImport.inferredKind(for: item.base)
                guard current.entry(named: name) == nil else {
                    print("the store has \(name) already: left as it is")
                    continue
                }
                let secret: SecretBytes = switch item.source {
                case .file(let path): try SecretsImportCommand.readFile(path)
                case .value(let value): SecretBytes(utf8: value)
                }
                do { try VaultImport.validate(secret, kind: kind) } catch let e as VaultError {
                    secret.wipe()
                    let from = if case .file(let path) = item.source { path } else { "its value" }
                    throw VaultError(.invalidSecret, "\(item.base) (\(from)): \(e.cause)", fix: "correct it in \(path)")
                }
                new.append((name, kind, VaultEntry.Metadata(teamID: teamId, keyID: item.keyID, issuerID: item.issuerID, created: Date()), secret, item))
            }
            if !new.isEmpty {
                try current.requireWritable()
                let reason = "importing \(new.map(\.name).joined(separator: ", "))"
                try store.unlock(current, remember: remember, reason: reason)
                try store.update(reason: reason) { catalog in
                    try SecretStoreCLI.same(catalog, as: current)
                    for entry in new where catalog.entry(named: entry.name) != nil { throw SecretsImportCommand.exists(entry.name) }
                    return new.map { .add(name: $0.name, kind: $0.kind, metadata: $0.metadata, secret: $0.secret) }
                }
                for entry in new { print("imported \(entry.name) (\(entry.kind.rawValue)) into the secret store") }
                for entry in new {
                    if case .file(let secretFile) = entry.item.source { try SecretStoreCLI.offerToDelete(secretFile) }
                }
            }
            if plan.left.isEmpty { print("\(path) has nothing else: remove it, and xless run reads the store") } else {
                print("\(path) is as it was: remove the lines of \(plan.moved.joined(separator: ", "))")
                print("not moved: \(plan.left.joined(separator: ", ")) (a password under a name of your own: xless secrets import NAME --file <file> --kind password; anything else: set it in the environment, or keep its line)")
            }
        }
    }
}
