import Foundation

enum BatchMutationDomain: Sendable {
    case entries
    case feeds
    case tags
}

/// Centralizes UI-facing mutation locking while batch tagging is active.
///
/// The current policy is intentionally strict: an active batch lifecycle
/// blocks entry, feed, and tag mutations from interactive surfaces.
struct BatchMutationLock: Equatable, Sendable {
    let isTagBatchLifecycleActive: Bool

    func blocks(_ domain: BatchMutationDomain) -> Bool {
        switch domain {
        case .entries, .feeds, .tags:
            return isTagBatchLifecycleActive
        }
    }

    var blocksEntryMutations: Bool { blocks(.entries) }
    var blocksFeedMutations: Bool { blocks(.feeds) }
    var blocksTagMutations: Bool { blocks(.tags) }
}
