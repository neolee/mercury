//
//  ReaderPipelineVersion.swift
//  Mercury
//

/// Explicit version constants for each persisted reader pipeline layer.
///
/// Bump the relevant constant when the corresponding transformation rules change.
/// A null or missing stored version is treated as version 0 and always mismatches,
/// triggering a rebuild of that layer and all downstream layers on next open.
enum ReaderPipelineVersion {
    /// Bump when Readability extraction or cleanup rules change.
    static let readability: Int = 1
    /// Bump when Readability-HTML-to-Markdown conversion rules change.
    static let markdown: Int = 1
    /// Bump when Markdown-to-reader-HTML rendering rules change.
    static let readerRender: Int = 1
}
