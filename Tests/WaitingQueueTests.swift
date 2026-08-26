import Foundation
import Testing
@testable import Mosaic

struct WaitingQueueTests {

    @Test func emptyQueueHasNoOldest() {
        #expect(WaitingQueue.oldestWaiting(in: []) == nil)
    }

    @Test func singleCandidateIsOldest() {
        let id = UUID()
        let candidates = [WaitingCandidate(id: id, attentionRaisedAt: 10)]
        #expect(WaitingQueue.oldestWaiting(in: candidates) == id)
    }

    @Test func picksTheEarliestTimestampRegardlessOfArrayOrder() {
        let oldest = UUID()
        let middle = UUID()
        let newest = UUID()
        let candidates = [
            WaitingCandidate(id: newest, attentionRaisedAt: 300),
            WaitingCandidate(id: oldest, attentionRaisedAt: 100),
            WaitingCandidate(id: middle, attentionRaisedAt: 200),
        ]
        #expect(WaitingQueue.oldestWaiting(in: candidates) == oldest)
    }

    // FIFO, not LIFO or spatial order (ADR 007): repeated jumps should drain the
    // waiting set in wait order, never re-surface an already-attended terminal,
    // and never starve the newest arrival.
    @Test func fifoDrainsInWaitOrderAcrossRepeatedCalls() {
        let first = WaitingCandidate(id: UUID(), attentionRaisedAt: 1)
        let second = WaitingCandidate(id: UUID(), attentionRaisedAt: 2)
        let third = WaitingCandidate(id: UUID(), attentionRaisedAt: 3)
        var pending = [third, first, second]

        #expect(WaitingQueue.oldestWaiting(in: pending) == first.id)
        pending.removeAll { $0.id == first.id }
        #expect(WaitingQueue.oldestWaiting(in: pending) == second.id)
        pending.removeAll { $0.id == second.id }
        #expect(WaitingQueue.oldestWaiting(in: pending) == third.id)
    }

    @Test func tiesResolveDeterministically() {
        let a = WaitingCandidate(id: UUID(), attentionRaisedAt: 5)
        let b = WaitingCandidate(id: UUID(), attentionRaisedAt: 5)
        #expect(WaitingQueue.oldestWaiting(in: [a, b]) == a.id)
    }
}
