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
    static let configuration = CommandConfiguration(commandName: "bootstrap", abstract: "Create a signing key + certificate (one-time).")

    @Option(help: "distribution, developer-id or installer (the Mac App Store .pkg)") var type: CertificateKind
    @Option(help: "Where to write the private key (mode 0600).") var out: String
    @Flag(help: "Create a certificate even if some already exist.") var allowNew = false
    @Flag(help: "Only write key + CSR (<out>.csr) for manual upload at developer.apple.com.") var csrOnly = false

    func run() async throws {
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
        Store it as the secret \(type.secretName) (or \(type.secretName)_FILE) in your CI and password manager, then delete the local copy.
        """)
    }
}
