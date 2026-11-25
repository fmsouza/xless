#if os(Windows) || XLESS_WINDOWS_TARGETS
import Foundation
import XlessCore

/// A command's side of the agents where there are none: Windows. What tells an agent which program it talks to, and whose terminal's, is
/// the kernel's word elsewhere, and has no counterpart there; so nothing is kept for a later command, and each one asks
/// (docs/security.md).
public final class AgentClient: Sendable {
    public static let none = AgentError(.unavailable, "nothing can be kept unlocked on Windows yet", fix: "run without it: each command asks; in CI, set the variables (docs/secrets.md)")

    public init(terms: AgentTerms = AgentTerms(), session: String? = nil) {}

    public var obstacle: AgentError? { Self.none }
    public var problem: AgentError? { nil }
    public func get(_ name: String, using: Bool = true, accept: (SecretBytes) -> Bool) -> SecretBytes? { nil }
    public func get(_ name: String, using: Bool = true, witness: () -> AgentWitness?) -> SecretBytes? { nil }
    public func put(_ seeds: [AgentSeed], witness: () -> AgentWitness? = { nil }) throws { throw Self.none }
    @discardableResult public func drop(prefix: String, label: String = "") -> AgentDropped { AgentDropped(count: 0, unreached: nil) }
    @discardableResult public func discard(_ names: [String], witness: () -> AgentWitness? = { nil }) -> Bool { false }
    public func lockAll() throws -> AgentLocked { AgentLocked(ended: 0, unanswered: []) }
    public func leases() -> [AgentStatus] { [] }
    public func statuses() -> [AgentStatus] { [] }
}
#endif
