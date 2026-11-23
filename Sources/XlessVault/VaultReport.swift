import Foundation

/// What `xless secrets list` and `status` print: names, kinds and metadata, never a value.
public enum VaultReport {
    static func day(_ d: Date?) -> String {
        guard let d else { return "-" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public static func list(_ file: some SecretEntries) -> String {
        guard !file.entries.isEmpty else { return "The secret store is empty (add a key with `xless secrets import`)." }
        let header = ["NAME", "KIND", "TEAM", "KEY ID", "ISSUER ID", "CERTIFICATE", "TYPE", "ROLE", "SERVICES", "CREATED", "EXPIRES"]
        let rows = file.entries.sorted { $0.name < $1.name }.map { e in
            let m = e.metadata
            return [e.name, e.kind.rawValue, m.teamID ?? "-", m.keyID ?? "-", m.issuerID ?? "-", m.certificateID ?? "-",
                    m.certificateType ?? "-", m.role ?? "-", m.services ?? "-", day(m.created), day(m.expires)]
        }
        let widths = header.indices.map { i in ([header] + rows).map { $0[i].count }.max() ?? 0 }
        return ([header] + rows).map { row in
            row.indices.map { i in i == row.count - 1 ? row[i] : row[i].padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// - Parameter unlocked: whether the unlock cache holds this store's key (nil: no cache here).
    public static func status(location: VaultLocation, file: VaultFile?, unlocked: Bool?) -> String {
        guard let file else {
            return "No secret store at \(location.file.path) (create one with `xless secrets init`)."
        }
        let kdf = file.kdf
        return [
            "Store:    \(location.file.path)",
            "Format:   \(file.format) version \(file.version)" + formatNote(file),
            "Entries:  \(file.entries.count)",
            "KDF:      \(kdf.algorithm) (N=\(kdf.rounds), r=\(kdf.blockSize), p=\(kdf.parallelism)); entries sealed with AES-256-GCM",
            "Unlocked: " + (unlocked.map { $0 ? "yes, cached in the kernel keyring until it expires or `xless secrets lock`" : "no" }
                ?? "no (no kernel keyring here: each command asks the passphrase)"),
        ].joined(separator: "\n")
    }

    static func formatNote(_ file: VaultFile) -> String {
        if !file.isWritable {
            return " (written by a newer xless: this one reads the entries it knows but does not change the store; upgrade xless)"
        }
        if file.needsUpgrade { return " (its entries are sealed again with every field the next time a command unlocks it to change it)" }
        return ""
    }

    /// `xless secrets status` with a credential helper.
    public static func status(helper: HelperSecretStore, catalog: SecretCatalog) -> String {
        [
            "Store:    the credential helper \(helper.helper.command) (\(helper.helper.executable)), secrets.backend in config.yml",
            "Entries:  \(catalog.entries.count)",
            "Unlocked: up to the helper (its keyring or agent locks and unlocks itself)",
        ].joined(separator: "\n")
    }
}
