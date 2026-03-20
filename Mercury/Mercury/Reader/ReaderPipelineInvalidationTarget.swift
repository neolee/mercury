//
//  ReaderPipelineInvalidationTarget.swift
//  Mercury
//

import Foundation

/// Debug-oriented invalidation targets for the persisted Reader pipeline.
///
/// Version-only invalidation keeps stored payloads but marks the selected layer
/// as stale. `all` is the destructive option that removes persisted content and
/// forces a full fetch on the next rebuild.
nonisolated enum ReaderPipelineInvalidationTarget: Sendable {
    case all
    case readability
    case markdown
    case readerHTML
}
