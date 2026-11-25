import ArgumentParser
import Foundation
import XlessCore
import XlessVault

/// `xless secrets materialize`: plumbing for `xless run`, not shown in the help. Writes the
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
    /// (`xless run`'s --allow-disk-secrets; named so argv's secret lint has nothing to object to)
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
