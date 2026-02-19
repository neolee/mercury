import Foundation

struct SummaryStreamingCacheState: Sendable {
    var text: String
    var updatedAt: Date
}

enum SummaryStreamingCachePolicy {
    static let defaultTTL: TimeInterval = 15 * 60
    static let defaultCapacity: Int = 64

    static func evict<Key: Hashable>(
        states: [Key: SummaryStreamingCacheState],
        now: Date = Date(),
        ttl: TimeInterval = defaultTTL,
        capacity: Int = defaultCapacity,
        pinnedKeys: Set<Key> = []
    ) -> [Key: SummaryStreamingCacheState] {
        let normalizedTTL = max(0, ttl)
        let normalizedCapacity = max(1, capacity)

        var live = states.filter { key, value in
            if pinnedKeys.contains(key) {
                return true
            }
            return now.timeIntervalSince(value.updatedAt) <= normalizedTTL
        }

        guard live.count > normalizedCapacity else {
            return live
        }

        let removableKeys = live
            .filter { pinnedKeys.contains($0.key) == false }
            .sorted { lhs, rhs in
                lhs.value.updatedAt < rhs.value.updatedAt
            }
            .map(\.key)

        var overflow = live.count - normalizedCapacity
        for key in removableKeys where overflow > 0 {
            live[key] = nil
            overflow -= 1
        }

        return live
    }
}
