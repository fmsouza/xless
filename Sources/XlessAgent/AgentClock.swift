import CXlessProcess
import Foundation

/// The agent's clocks: one that counts while the system sleeps, one that does not (their difference grows by each
/// sleep), and the wall clock.
public struct AgentClock: Sendable {
    public struct Now: Sendable, Equatable {
        /// Milliseconds, sleep included.
        public var continuous: Int64
        /// Milliseconds, sleep excluded.
        public var awake: Int64
        public var wall: Date

        public init(continuous: Int64, awake: Int64, wall: Date) {
            self.continuous = continuous; self.awake = awake; self.wall = wall
        }
    }

    let read: @Sendable () -> Now

    public init(_ read: @escaping @Sendable () -> Now) { self.read = read }

    public var now: Now { read() }

    public static let system = AgentClock {
        Now(continuous: xless_clock_continuous_ms(), awake: xless_clock_awake_ms(), wall: Date())
    }
}

/// A moment that has passed as soon as either clock says so: a wall clock set back does not put it off, and neither does
/// a system whose continuous clock did not count a sleep.
struct AgentDeadline {
    let continuous: Int64
    let wall: Date

    init(_ now: AgentClock.Now, in seconds: Int) {
        continuous = now.continuous + Int64(seconds) * 1000
        wall = now.wall + TimeInterval(seconds)
    }

    private init(continuous: Int64, wall: Date) { self.continuous = continuous; self.wall = wall }

    func later(by seconds: Int) -> AgentDeadline {
        AgentDeadline(continuous: continuous + Int64(seconds) * 1000, wall: wall + TimeInterval(seconds))
    }

    /// The seconds since this moment, by the clock that says the most.
    func age(_ now: AgentClock.Now) -> Int {
        max(0, Int((now.continuous - continuous + 999) / 1000), Int(now.wall.timeIntervalSince(wall).rounded(.up)))
    }

    func remaining(_ now: AgentClock.Now) -> Int {
        max(0, min(Int((continuous - now.continuous + 999) / 1000), Int(wall.timeIntervalSince(now.wall).rounded(.up))))
    }

    func passed(_ now: AgentClock.Now) -> Bool { now.continuous >= continuous || now.wall >= wall }

    static func earlier(_ a: AgentDeadline, _ b: AgentDeadline) -> AgentDeadline {
        AgentDeadline(continuous: min(a.continuous, b.continuous), wall: min(a.wall, b.wall))
    }
}
