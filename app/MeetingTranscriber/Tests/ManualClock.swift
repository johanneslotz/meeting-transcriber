import Foundation
import os

/// A clock a test advances by hand.
final class ManualClock: @unchecked Sendable {
    private let value: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        value = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date {
        value.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
