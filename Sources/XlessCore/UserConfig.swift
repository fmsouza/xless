import Foundation
import Yams

/// Where the secrets live: `secrets: { backend: vault }` (the encrypted store, the default) or
/// `secrets: { backend: helper, helper: <name> }` (the external credential helper `xless-credential-<name>` on PATH).
public enum SecretsBackend: Sendable, Equatable {
    case vault
    case helper(String)

    /// Lower-case letters, digits and `. _ -`, starting with a letter or digit, at most 64 characters: a name, never a
    /// path (`pass`, `secret-tool`).
    public static func isValidHelperName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9._-]{0,63}/) != nil
    }

    static let example = "secrets: { backend: helper, helper: pass } (or backend: vault, the default)"

    /// The `secrets` value of config.yml (nil: not set).
    static func parse(_ value: Any?, file: String) throws -> SecretsBackend {
        guard let value else { return .vault }
        func bad(_ why: String) -> XlessError {
            XlessError(.config, "\(file): \(why)", fix: "write it as \(example)")
        }
        guard let map = value as? [String: Any] else { throw bad("`secrets` is not a mapping") }
        if let extra = map.keys.sorted().first(where: { !["backend", "helper"].contains($0) }) {
            throw bad("`secrets` has an unknown key `\(extra)`")
        }
        let backend = map["backend"].map { "\($0)" } ?? "vault"
        switch backend {
        case "vault":
            guard map["helper"] == nil else { throw bad("`secrets.helper` is only for `backend: helper`") }
            return .vault
        case "helper":
            guard let name = map["helper"] as? String else { throw bad("`backend: helper` needs `helper: <name>`") }
            guard isValidHelperName(name) else {
                throw bad("`secrets.helper` \(name) is not a helper name (lower-case letters, digits, . _ -; xless runs xless-credential-<name> from PATH)")
            }
            return .helper(name)
        default:
            throw bad("`secrets.backend` \(backend) is neither vault nor helper")
        }
    }
}

/// The user's own xless settings, `$XDG_CONFIG_HOME/xless/config.yml` (else `~/.config/xless/config.yml`): plain
/// preferences, never a secret: `team`, the default Apple team (`xless team use`), `secrets`, where the secrets live
/// (`SecretsBackend`), and `unlock`, how long they may be held unlocked (`UnlockSettings`). Keys xless does not know are kept as they are when it writes the file (comments are not).
public struct UserConfig: Sendable, Equatable {
    public var team: String?

    public init(team: String? = nil) { self.team = team }

    public static func file(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = env["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("xless/config.yml")
        }
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent(".config/xless/config.yml")
    }

    /// The settings; empty when the file does not exist.
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> UserConfig {
        let raw = try read(file(env: env))
        return UserConfig(team: (raw["team"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Where the secrets live (`secrets:`); the vault when the file or the key is absent. A malformed value is an error,
    /// never a silent fallback to another backend.
    public static func secretsBackend(env: [String: String] = ProcessInfo.processInfo.environment) throws -> SecretsBackend {
        let url = file(env: env)
        return try SecretsBackend.parse(try read(url)["secrets"], file: url.path)
    }

    /// Changes the settings and writes the file (atomically, mode 0644), keeping the keys `UserConfig` does not know.
    public static func update(env: [String: String] = ProcessInfo.processInfo.environment, _ change: (inout UserConfig) -> Void) throws {
        let url = file(env: env)
        var raw = try read(url)
        var config = UserConfig(team: raw["team"] as? String)
        change(&config)
        if let team = config.team { raw["team"] = team } else { raw.removeValue(forKey: "team") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = raw.isEmpty ? "" : try Yams.dump(object: raw, sortKeys: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            throw XlessError(.config, "cannot write \(url.path): \(error.localizedDescription)", fix: "check that the directory is writable")
        }
    }

    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XlessError(.config, "cannot read \(url.path)", fix: "check its permissions, or remove it")
        }
        let object: Any?
        do { object = try Yams.load(yaml: text) } catch {
            throw XlessError(.config, "\(url.path) is not valid YAML", fix: "fix it, or remove it (it only holds preferences such as the default team)")
        }
        guard let object else { return [:] }
        guard let map = object as? [String: Any] else {
            throw XlessError(.config, "\(url.path) is not a YAML mapping", fix: "fix it, or remove it (e.g. `team: ABCDE12345`)")
        }
        return map
    }
}
