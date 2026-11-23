import Foundation
import Testing
@testable import XlessASC

/// Counts how many operations run at once.
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var most = 0
    private(set) var done = 0
    func enter() { lock.withLock { now += 1; most = max(most, now) } }
    func leave() { lock.withLock { now -= 1; done += 1 } }
}

@Test func theLimiterNeverRunsMoreThanItsLimitAtOnce() async throws {
    let limiter = AsyncLimiter(3)
    let count = InFlight()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                try await limiter.run {
                    count.enter()
                    try await Task.sleep(for: .milliseconds(5))
                    count.leave()
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(count.done == 12)
    #expect(count.most == 3)
}

@Test func aFailedOperationGivesItsPermitBack() async throws {
    struct Boom: Error {}
    let limiter = AsyncLimiter(1)
    await #expect(throws: Boom.self) { try await limiter.run { throw Boom() } }
    #expect(try await limiter.run { 42 } == 42, "the permit came back")
}

@Test func pollingBacksOffUpToItsCap() {
    #expect(AssetUploader.nextInterval(after: .seconds(3), cap: .seconds(30)) == .milliseconds(4500))
    #expect(AssetUploader.nextInterval(after: .seconds(25), cap: .seconds(30)) == .seconds(30))
    #expect(AssetUploader.nextInterval(after: .zero, cap: .seconds(30)) == .zero)
}
