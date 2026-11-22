import Foundation

public struct Secrets: Sendable {
    let env: [String: String]

    public init(env: [String: String] = ProcessInfo.processInfo.environment) { self.env = env }

    /// Value of NAME, else contents of the file at NAME_FILE, else nil. Handing out a value enters `SecretScope`.
    public func optional(_ name: String) throws -> String? {
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
        return nil
    }

    public func required(_ name: String, stage: Stage) throws -> String {
        guard let v = try optional(name) else {
            throw XlessError(stage, "missing secret \(name)", fix: "set \(name) or \(name)_FILE")
        }
        return v
    }

    /// For IDs (key ID, issuer ID): trimmed of whitespace and newlines.
    public func identifier(_ name: String, stage: Stage) throws -> String {
        try required(name, stage: stage).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
