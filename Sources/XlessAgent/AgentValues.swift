import Foundation
import XlessCore

// What an agent holds and says of it: the values that a command gives it and gets from it.

/// A secret an agent is started with.
public struct AgentSeed: Sendable {
    public let name: String
    public let label: String
    public let secret: SecretBytes
    public let hold: SecretHold
    /// The seconds since it was typed, rounded up: 0 only when it was typed for this.
    public let typedAgo: Int

    public init(name: String, label: String, secret: SecretBytes, hold: SecretHold, typedAgo: Int = 0) {
        self.name = name; self.label = label; self.secret = secret; self.hold = hold; self.typedAgo = typedAgo
    }
}

/// What a command's settings (`unlock:` in config.yml) ask of an agent it uses: an agent keeps to the strictest of those
/// it was told, for as long as it runs.
public struct AgentTerms: Sendable, Equatable {
    /// The longest anything is held after it was typed, in seconds.
    public var maximum: Int
    public var lockOnSleep: Bool
    public var lockOnScreenLock: Bool

    public init(maximum: Int = HoldDuration.maximum, lockOnSleep: Bool = true, lockOnScreenLock: Bool = true) {
        self.maximum = maximum; self.lockOnSleep = lockOnSleep; self.lockOnScreenLock = lockOnScreenLock
    }
}

/// A POSIX session, told apart from a later one with the same number by when its leader started.
public struct AgentSession: Sendable, Hashable {
    public let id: Int32
    public let leaderStart: UInt64

    public init(id: Int32, leaderStart: UInt64) { self.id = id; self.leaderStart = leaderStart }

    /// Whether it can be granted: it has a number in this PID namespace, and its leader runs.
    public var isUsable: Bool { id > 0 && leaderStart != 0 }
}

public struct AgentItemStatus: Sendable, Equatable {
    public let name: String
    /// What it is for (the store's path), or empty.
    public let label: String
    /// Seconds until it is dropped whatever happens.
    public let remaining: Int
    public let idle: Int
    /// Seconds until it is dropped when nobody uses it.
    public let idleRemaining: Int
    /// Seconds since it was typed.
    public let typedAgo: Int

    public init(name: String, label: String, remaining: Int, idle: Int, idleRemaining: Int, typedAgo: Int = 0) {
        self.name = name; self.label = label; self.remaining = remaining; self.idle = idle; self.idleRemaining = idleRemaining
        self.typedAgo = typedAgo
    }
}

/// What shows that a command and an agent have the same store's key.
public struct AgentWitness: Sendable {
    /// The item an agent holds it as.
    public let item: String
    public let key: SecretBytes

    public init(item: String, key: SecretBytes) { self.item = item; self.key = key }
}

/// An agent that is there and did not do as it was asked.
public struct AgentUnanswered: Sendable, Equatable {
    /// 0: not known.
    public let pid: Int32
    public let path: String

    public init(pid: Int32, path: String) { self.pid = pid; self.path = path }

    public var cause: String { "an xless agent (\(pid > 0 ? "process \(pid), " : "")\(path)) does not answer: what it holds may still be held" }
    public var fix: String {
        // By the time it is read the process may have ended, and its pid be another one's.
        let end = pid > 0 ? "if `ps -p \(pid) -o args=` still says `xless __agent`, end it (`kill -9 \(pid)`)" : "end every agent of yours (`pkill -9 -f 'xless __agent'`)"
        return "\(end), then run `xless lock`"
    }
}

/// What a drop came to.
public struct AgentDropped: Sendable, Equatable {
    public let count: Int
    /// Why not every agent could be told; nil: every one was.
    public let unreached: AgentError?

    public init(count: Int, unreached: AgentError?) { self.count = count; self.unreached = unreached }
}

/// What `lockAll` came to.
public struct AgentLocked: Sendable, Equatable {
    public let ended: Int
    public let unanswered: [AgentUnanswered]

    public init(ended: Int, unanswered: [AgentUnanswered]) { self.ended = ended; self.unanswered = unanswered }
}

/// What an agent says of itself.
public struct AgentStatus: Sendable, Equatable {
    /// Whether it serves this process's session: only then are its items named.
    public let isGranted: Bool
    public let count: Int
    /// The seconds its longest hold has left.
    public let remaining: Int
    /// How many terminal sessions it serves.
    public let sessions: Int
    public let items: [AgentItemStatus]
    /// It is a process of this very session, by the kernel's word.
    public let isSameSession: Bool
    /// When it is on a lease; its items are then named for every process of the user, by kind.
    public let lease: AgentLeaseStatus?

    public init(isGranted: Bool, count: Int, remaining: Int, sessions: Int, items: [AgentItemStatus], isSameSession: Bool, lease: AgentLeaseStatus? = nil) {
        self.isSameSession = isSameSession
        self.lease = lease
        self.isGranted = isGranted
        self.count = count
        self.remaining = remaining
        self.sessions = sessions
        self.items = items
    }
}

/// Of an agent on a lease (`xless session`).
public struct AgentLeaseStatus: Sendable, Equatable {
    /// The command it is for.
    public let command: String
    /// The seconds it has left at most.
    public let remaining: Int

    public init(command: String, remaining: Int) { self.command = command; self.remaining = remaining }
}
