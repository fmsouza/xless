#if os(Windows) || XLESS_WINDOWS_TARGETS
import Foundation
import XlessCore

/// Windows has no credential helpers yet (`secrets: { backend: helper }` starts another program, which needs what CredentialHelper.swift
/// has on other systems): the backend is refused, and no helper is ever found or started.
public struct CredentialHelper: Sendable {
    public static let prefix = "xless-credential-"

    public enum Verb: String, Sendable { case get, store, erase, list }

    public struct Answer {
        public let status: Int32
        public let output: SecretBytes
    }

    public let name: String
    public let executable: String
    public var command: String { Self.prefix + name }

    public static func find(name: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> CredentialHelper {
        throw VaultError(.helper, "credential helpers do not work on Windows yet (secrets.backend is helper, helper \(name))",
                         fix: "set `secrets: { backend: vault }` in \(UserConfig.file(env: env).path)")
    }

    public func run(_ verb: Verb, input: SecretBytes?) throws -> Answer {
        throw VaultError(.helper, "credential helpers do not work on Windows yet", fix: "use the encrypted store (`secrets: { backend: vault }`)")
    }
}
#endif
