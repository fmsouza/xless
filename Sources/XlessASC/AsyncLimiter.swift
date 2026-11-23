/// At most `limit` operations at once: `run` waits for a permit, runs the operation, and gives the permit back
/// whether it succeeded or threw. Waiters are served in arrival order.
public actor AsyncLimiter {
    public let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ limit: Int) { self.limit = max(1, limit) }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // The permit is handed over by `release`: `running` stays as it is.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    public nonisolated func run<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
