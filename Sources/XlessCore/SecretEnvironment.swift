import Foundation

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

    /// Adds a secret's name for the rest of this process: a name of the user's own that this run reads a secret from
    /// (a demo account password's `passwordSecret`), registered when the configuration names it and whenever `Secrets`
    /// is asked for it. Child processes never see it nor its `_FILE` form, like the entries above. A name that is not
    /// an environment variable's (`[A-Za-z_][A-Za-z0-9_]*`; a store entry's `@TEAM` is dropped) is ignored.
    public static func scrub(_ name: String) {
        let base = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        guard let first = base.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic),
              base.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) })
        else { return }
        registered.add(base)
    }

    /// Every name a child's environment loses: the entries' and the registered names, each with its `_FILE` form.
    public static var scrubbed: [String] {
        names + registered.names.sorted().filter { !names.contains($0) }.flatMap { [$0, "\($0)_FILE"] }
    }

    private static let registered = Registered()

    /// Whether a secret's name (as a store entry, optionally `@TEAM`) is a key's or a token's: refused where a password
    /// (the App Review demo account's) is meant, so a key is never sent to Apple as a password.
    public static func isKeyOrToken(_ name: String) -> Bool {
        let base = (name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? name).uppercased()
        if base == "XLESS_DEMO_PASSWORD" { return false }
        if isSecret(base) || base.hasPrefix("ASC_") { return true }
        return ["_KEY", "_TOKEN", "_P8", "_PEM", "_SECRET"].contains { base.hasSuffix($0) || base.hasSuffix($0 + "_FILE") }
    }

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

private final class Registered: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String> = []
    func add(_ name: String) { lock.withLock { _ = stored.insert(name) } }
    var names: Set<String> { lock.withLock { stored } }
}
