//
//  FeedParserVersion.swift
//  Mercury
//

/// Explicit version constant for feed-parser verification and historical repair.
///
/// A null stored version is treated as version 0 and means the feed has not yet
/// been verified against the current parser repair rules.
nonisolated enum FeedParserVersion {
    static let current: Int = 1
}
