import Foundation

/// Where a secret comes from when the environment does not have it: the encrypted secret store (`xless secrets`). Asked
/// only after `NAME` and `NAME_FILE`, so CI (which sets them) never opens it. Returns nil when it has no such secret.
public protocol SecretFallback: Sendable {
    func lookup(_ name: String, stage: Stage) throws -> String?
    /// The same source, preferring `team`'s secrets: its entries, else ones recorded for no team; another team's are
    /// never handed out. A project's run (`ship`) knows its team. Default: unchanged.
    func preferring(team: String) -> any SecretFallback
}

extension SecretFallback {
    public func preferring(team: String) -> any SecretFallback { self }
}

public struct Secrets: Sendable {
    let env: [String: String]
    let fallback: (any SecretFallback)?

    /// `fallback` defaults to the one the CLI installed at startup (`install(_:)`); none in tests and libraries.
    public init(env: [String: String] = ProcessInfo.processInfo.environment, fallback: (any SecretFallback)? = Secrets.installedFallback) {
        self.env = env
        self.fallback = fallback
    }

    /// These secrets, the store's lookups preferring `team` (see `SecretFallback.preferring`); unchanged for an empty team.
    public func preferring(team: String) -> Secrets {
        guard !team.isEmpty, let fallback else { return self }
        return Secrets(env: env, fallback: fallback.preferring(team: team))
    }

    private static let installed = Installed()

    /// The process-wide fallback every `Secrets()` uses (the CLI installs the secret store's resolver once, in `main`).
    public static var installedFallback: (any SecretFallback)? { installed.value }

    public static func install(_ fallback: (any SecretFallback)?) { installed.value = fallback }

    /// Value of NAME, else contents of the file at NAME_FILE, else the secret store's (asked last, and only then).
    /// Handing out a value enters `SecretScope`.
    /// The name joins `SecretEnvironment.scrub`: a tool xless runs later never sees it in its environment.
    public func optional(_ name: String, stage: Stage = .config) throws -> String? {
        SecretEnvironment.scrub(name)
        if let v = env[name], !v.isEmpty {
            SecretScope.enter()
            return v
        }
        if let path = env["\(name)_FILE"], !path.isEmpty {
            SecretScope.enter()
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw XlessError(.config, "\(name)_FILE points to an unreadable file", fix: "check the path in \(name)_FILE")
            }
            return s
        }
        if let fallback, let v = try fallback.lookup(name, stage: stage) {
            SecretScope.enter()
            return v
        }
        return nil
    }

    public func required(_ name: String, stage: Stage) throws -> String {
        guard let v = try optional(name, stage: stage) else {
            throw XlessError(stage, "missing secret \(name)", fix: Self.missingFix(name))
        }
        return v
    }

    /// For IDs (key ID, issuer ID): trimmed of whitespace and newlines.
    public func identifier(_ name: String, stage: Stage) throws -> String {
        try required(name, stage: stage).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func missingFix(_ name: String) -> String {
        switch name {
        case "ASC_KEY_ID", "ASC_ISSUER_ID":
            "set \(name) or \(name)_FILE, or keep the API key in the secret store with its IDs (`xless secrets import ASC_KEY_P8 --file AuthKey_<KEY_ID>.p8 --issuer-id <ISSUER_ID>`)"
        default:
            "set \(name) or \(name)_FILE, or keep it in the secret store (`xless secrets import \(name) --file <path>`)"
        }
    }
}

private final class Installed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any SecretFallback)?
    var value: (any SecretFallback)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
