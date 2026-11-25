import XlessCore

/// A failure of the xless agent or of a command talking to it. Names paths and what to do, never a secret.
public struct AgentError: Error, Equatable, Sendable, StageReportableError, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The message is not one of this protocol's, or lies about itself.
        case malformed
        /// The agent was started by another version of xless.
        case version
        /// The agent does not serve this process (`AgentState.isGranted`).
        case refused
        /// The agent's directory or socket is not safe to use.
        case unsafePath
        /// No agent can run here.
        case unavailable
        /// The other end closed, or did not answer in time.
        case gone
        /// What was asked is outside the agent's limits.
        case limit
    }

    public let kind: Kind
    public let cause: String
    public let fix: String

    public init(_ kind: Kind, _ cause: String, fix: String) {
        self.kind = kind
        self.cause = cause
        self.fix = fix
    }

    public var description: String { "\(cause) — \(fix)" }

    public func stageError(_ stage: Stage) -> XlessError { XlessError(stage, cause, fix: fix) }

    static func malformed(_ what: String) -> AgentError {
        AgentError(.malformed, "the xless agent's message is not valid (\(what))", fix: "run `xless lock`, then `xless unlock`")
    }

    public static func versionMismatch(theirs: String) -> AgentError {
        AgentError(.version, "the xless agent that holds your unlock was started by another xless (\(theirs)), so this one does not use it",
                   fix: "run `xless lock`, then `xless unlock`")
    }

    static func limit(_ what: String) -> AgentError {
        AgentError(.limit, "the xless agent does not take \(what)", fix: "run `xless lock`, then `xless unlock`")
    }

    static let gone = AgentError(.gone, "the xless agent closed the connection or did not answer", fix: "run `xless lock`, then `xless unlock`")
}

/// The bounds of what an agent holds and reads, whoever asks.
public enum AgentLimits {
    /// The longest anything is held: 7 days, whatever is asked.
    public static let seconds = HoldDuration.maximum
    static let items = 8
    static let itemBytes = 128 << 10
    static let nameBytes = 200
    static let labelBytes = 1024
    static let sessions = 64
    /// The sockets a client looks at.
    static let sockets = 32
    static let connections = 32
    /// A message from a peer the agent does not serve (a greeting, a lock), and from one it does (an item).
    static let smallMessage = 4 << 10
    static let message = itemBytes + (8 << 10)
    static let requestsPerConnection = 64
    static let connectionMilliseconds: Int64 = 10_000
}
