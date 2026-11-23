/// Every environment variable that carries a secret, in one place. Each name also counts as `<NAME>_FILE` (the path to a
/// file holding it, `Secrets`' fallback). A new secret joins the list here, in the same change that first reads it:
/// child processes never see any of them (`Shell.scrubbedEnvironment`), and overlays may not set them.
public enum SecretEnvironment {
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let purpose: String
    }

    public static let entries: [Entry] = [
        Entry(name: "ASC_KEY_ID", purpose: "App Store Connect API key ID"),
        Entry(name: "ASC_ISSUER_ID", purpose: "App Store Connect API key issuer ID"),
        Entry(name: "ASC_KEY_P8", purpose: "App Store Connect API private key (.p8)"),
        Entry(name: "XLESS_DIST_KEY", purpose: "Apple Distribution signing key (PEM)"),
        Entry(name: "XLESS_DEVID_KEY", purpose: "Developer ID Application signing key (PEM)"),
        Entry(name: "XLESS_INSTALLER_KEY", purpose: "Mac Installer Distribution signing key (PEM)"),
        Entry(name: "XLESS_DEMO_PASSWORD", purpose: "App Review demo account password (`store push`, app.yml's review.demoAccount.passwordSecret)"),
    ]

    /// Every entry's name and its `_FILE` variant.
    public static let names: [String] = entries.flatMap { [$0.name, "\($0.name)_FILE"] }

    public static func isSecret(_ variable: String) -> Bool { names.contains(variable) }

    /// Whether a command-line option or argument named `name` (`--api-key`, `password`, `privateKey`) would carry a
    /// secret. Secrets never come from argv: it is visible to every user in `ps` and /proc/<pid>/cmdline, and lands in
    /// shell history. An option giving the *path* of a file or an ID is fine (`--key-file`, `--key-id`).
    public static func argumentLooksSecret(_ name: String) -> Bool {
        let words = words(of: name)
        if let last = words.last, words.count > 1, harmlessQualifiers.contains(last) { return false }
        if words.contains(where: secretWords.contains) { return true }
        let joined = words.joined()
        return words == ["key"] || ["privatekey", "apikey", "authkey", "accesskey", "signingkey"].contains(where: joined.contains)
    }

    private static let secretWords: Set<String> = [
        "password", "passwd", "passphrase", "pass", "secret", "secrets", "token", "cookie", "cookies",
        "credential", "credentials", "otp", "p8", "scnt", "pem", "jwt",
    ]
    /// As the last word: `--private-key-file`, `--password-file`, `--api-key-id` name where a secret is, or something
    /// that is not one.
    private static let harmlessQualifiers: Set<String> = ["file", "path", "id", "name", "kind", "type"]

    /// `--api-key` / `api_key` / `apiKey` → ["api", "key"].
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousLower = false
        for ch in name.drop(while: { $0 == "-" }) {
            if ch == "-" || ch == "_" || ch == "." || ch == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousLower = false
                continue
            }
            if ch.isUppercase, previousLower, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current += ch.lowercased()
            previousLower = ch.isLowercase || ch.isNumber
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
