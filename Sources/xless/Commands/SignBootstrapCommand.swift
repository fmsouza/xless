import ArgumentParser
import Foundation
import XlessASC
import XlessCore
import XlessSign

extension CertificateKind: ExpressibleByArgument {}

struct SignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sign", abstract: "Sign the finalized bundle (.xless/build/<platform>/signed), or bootstrap signing keys.",
                                                    subcommands: [SignRunCommand.self, SignBootstrapCommand.self], defaultSubcommand: SignRunCommand.self)
}

struct SignRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Sign the finalized bundle.")
    @OptionGroup var options: ProjectOptions
    func run() async throws { print(try await StageRunner.sign(Context.load(options)).path) }
}

struct SignBootstrapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bootstrap", abstract: "Create a signing key + certificate (one-time); the key goes into the secret store.",
        discussion: """
        The `xless certs create` of the three certificates `sign` uses: the key is generated and sealed into the secret \
        store (`xless secrets init` first) as XLESS_DIST_KEY, XLESS_DEVID_KEY or XLESS_INSTALLER_KEY (@<TEAM_ID> with the \
        team saved by `xless team use`) before the certificate is requested, once. With --out, the key is written to that \
        file instead (mode 0600, never overwritten), as before.
        """)

    @Option(help: "distribution, developer-id or installer (the Mac App Store .pkg)") var type: CertificateKind
    @Option(help: "Write the private key to this new file (mode 0600) instead of the secret store.") var out: String?
    @Flag(help: "Create a certificate even if some already exist.") var allowNew = false
    @Flag(help: "Only write key + CSR (<out>.csr) for manual upload at developer.apple.com (needs --out).") var csrOnly = false

    func validate() throws {
        if csrOnly, out == nil { throw ValidationError("--csr-only writes the key and the CSR to files: pass --out <key file>") }
    }

    func run() async throws {
        SecretScope.enter() // generates a private key and reads the App Store Connect key
        guard let out else { return try await runIntoStore() }
        // Persist the key exclusively BEFORE any network call so a write failure can never burn a certificate slot.
        let key = try await withStage(.sign) { try SigningKey.generate() }
        try key.writeExclusively(toPath: out)
        if csrOnly {
            do {
                try await withStage(.sign) {
                    try SigningKey.writeExclusively(Data(try key.csrPEM(commonName: "xless").utf8), toPath: "\(out).csr", mode: 0o644)
                }
            } catch {
                try? FileManager.default.removeItem(atPath: out)
                throw error
            }
        } else {
            do {
                try await withStage(.sign) {
                    let client = ASCClient(credentials: try ASCCredentials.fromSecrets(Secrets(), stage: .sign))
                    let cert = try await CertificateService(client: client).bootstrap(kind: type, allowNew: allowNew, key: key)
                    print("created certificate \(cert.id) (\(cert.attributes.certificateType ?? type.createType))")
                }
            } catch {
                // Keep the key only if the certificate may exist (ambiguous create); otherwise it is useless.
                if !((error as? XlessError)?.isAmbiguousCertificateCreation ?? false) {
                    try? FileManager.default.removeItem(atPath: out)
                }
                throw error
            }
        }
        print("""
        wrote private key to \(out)\(csrOnly ? " and CSR to \(out).csr" : "")
        Keep it in the secret store (`xless secrets import \(type.secretName) --file \(out)`) and/or as the secret \(type.secretName) (or \(type.secretName)_FILE) in your CI, then delete the local copy.
        """)
    }

    /// The default: `xless certs create --type <kind>` with bootstrap's own checks (no second certificate without
    /// --allow-new), at stage `sign`.
    private func runIntoStore() async throws {
        try await withStage(.sign) {
            let team = AccountSession.savedTeam()
            let file = try APIKeyWebCLI.existingStore()
            let entry = CertificateKeyStore.entryName(base: type.secretName, team: team)
            try CertificateKeyStore.precheck(file, name: entry, base: type.secretName, team: team, stage: .sign)
            let client = ASCClient(credentials: try ASCCredentials.fromSecrets(Secrets(), stage: .sign))
            let creation = CertificateCreation(api: ASCCertificates(resources: ASCResources(client: client)), stage: .sign, refuseIfAny: !allowNew,
                                               say: AppleWebCLI.say)
            let created = try await creation.run(type: type.certificateType, relatedID: nil, entry: entry, team: team, keys: {
                let file = try APIKeyWebCLI.existingStore()
                return CertificateKeyStore(store: APIKeyWebCLI.store, fileID: file.id,
                                           dataKey: try SecretStoreCLI.unlock(file, remember: nil, reason: "storing the new signing key"))
            })
            print(created.text, terminator: "")
            print("`xless sign` reads it from the store as \(type.secretName); CI sets \(type.secretName) (or \(type.secretName)_FILE) instead: export it once with `xless secrets export \(created.entry ?? entry) --out <file>`.")
        }
    }
}
