import Foundation

/// A repeatable tick source for the engine's injected `sleep`: each `wait()`
/// parks until the test calls `fire()`.
actor TickSource {
    private(set) var requestedIntervals: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var credits = 0

    func wait(interval: TimeInterval) async {
        requestedIntervals.append(interval)
        if credits > 0 {
            credits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        if waiters.isEmpty {
            credits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
