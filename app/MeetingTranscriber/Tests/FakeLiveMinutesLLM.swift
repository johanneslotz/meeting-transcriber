import Foundation
@testable import MeetingTranscriber

/// Scripted `LiveMinutesLLMClient`: replays queued replies, records every
/// request, and can park a call on a gate so a test orders it against other
/// work. Replies run out into a valid fixed summary so a test only scripts the
/// calls it cares about.
actor FakeLiveMinutesLLM: LiveMinutesLLMClient {
    struct Request {
        let system: String
        let user: String
    }

    private(set) var requests: [Request] = []
    private var replies: [Result<String, any Error>]
    private let gate: AsyncGate?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(replies: [Result<String, any Error>] = [], gate: AsyncGate? = nil) {
        self.replies = replies
        self.gate = gate
    }

    static let fallbackReply = LiveMinutesTestData.json(topics: ["Fallback topic"])

    func complete(system: String, user: String) async throws -> String {
        requests.append(Request(system: system, user: user))
        resumeWaiters()
        if let gate { await gate.wait() }
        guard !replies.isEmpty else { return Self.fallbackReply }
        return try replies.removeFirst().get()
    }

    /// Suspends until at least `count` requests have arrived.
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { requests.count >= $0.count }
        waiters.removeAll { requests.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
