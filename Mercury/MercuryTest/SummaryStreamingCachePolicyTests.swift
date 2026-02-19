import Foundation
import Testing
@testable import Mercury

@Suite("Summary Streaming Cache Policy")
struct SummaryStreamingCachePolicyTests {
    @Test("Expired non-pinned states are evicted")
    func evictsExpiredEntries() {
        let now = Date(timeIntervalSince1970: 10_000)
        let states: [Int: SummaryStreamingCacheState] = [
            1: SummaryStreamingCacheState(text: "old", updatedAt: now.addingTimeInterval(-61)),
            2: SummaryStreamingCacheState(text: "fresh", updatedAt: now.addingTimeInterval(-30))
        ]

        let trimmed = SummaryStreamingCachePolicy.evict(
            states: states,
            now: now,
            ttl: 60,
            capacity: 10
        )

        #expect(trimmed.keys.contains(1) == false)
        #expect(trimmed.keys.contains(2) == true)
    }

    @Test("Pinned state survives TTL eviction")
    func keepsPinnedExpiredEntries() {
        let now = Date(timeIntervalSince1970: 20_000)
        let states: [Int: SummaryStreamingCacheState] = [
            1: SummaryStreamingCacheState(text: "old-pinned", updatedAt: now.addingTimeInterval(-500)),
            2: SummaryStreamingCacheState(text: "fresh", updatedAt: now)
        ]

        let trimmed = SummaryStreamingCachePolicy.evict(
            states: states,
            now: now,
            ttl: 60,
            capacity: 10,
            pinnedKeys: [1]
        )

        #expect(trimmed.keys.contains(1) == true)
        #expect(trimmed.keys.contains(2) == true)
    }

    @Test("Capacity eviction removes oldest non-pinned first")
    func evictsOldestFirstWhenOverCapacity() {
        let now = Date(timeIntervalSince1970: 30_000)
        let states: [Int: SummaryStreamingCacheState] = [
            1: SummaryStreamingCacheState(text: "oldest", updatedAt: now.addingTimeInterval(-30)),
            2: SummaryStreamingCacheState(text: "middle", updatedAt: now.addingTimeInterval(-20)),
            3: SummaryStreamingCacheState(text: "newest", updatedAt: now.addingTimeInterval(-10)),
            4: SummaryStreamingCacheState(text: "pinned-old", updatedAt: now.addingTimeInterval(-100))
        ]

        let trimmed = SummaryStreamingCachePolicy.evict(
            states: states,
            now: now,
            ttl: 1_000,
            capacity: 2,
            pinnedKeys: [4]
        )

        #expect(trimmed.count == 2)
        #expect(trimmed.keys.contains(4) == true)
        #expect(trimmed.keys.contains(3) == true)
    }
}
