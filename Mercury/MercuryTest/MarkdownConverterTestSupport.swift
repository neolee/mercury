//
//  MarkdownConverterTestSupport.swift
//  MercuryTest
//
//  Shared helpers for MarkdownConverter and reader pipeline tests.
//  Import SwiftSoup for DOM-level assertions on round-tripped HTML.
//

import XCTest
import SwiftSoup
@testable import Mercury

// MARK: - Conversion helpers

/// Converts an HTML fragment to canonical Markdown using the persisted reader pipeline path.
func convertMarkdown(_ html: String) throws -> String {
    try MarkdownConverter.markdownFromPersisted(contentHTML: html, title: nil, byline: nil)
}

/// Renders Markdown to reader HTML using the production renderer.
func renderMarkdownToHTML(_ markdown: String) throws -> String {
    try ReaderHTMLRenderer.render(markdown: markdown, themeId: "light")
}

/// Full round-trip: HTML -> Markdown -> reader HTML.
func roundTrip(_ html: String) throws -> String {
    let markdown = try convertMarkdown(html)
    return try renderMarkdownToHTML(markdown)
}

// MARK: - DOM assertion helpers

/// Returns the number of elements matching `selector` in the HTML string.
func countElements(_ selector: String, in html: String) throws -> Int {
    let doc = try SwiftSoup.parse(html)
    return try doc.select(selector).size()
}

/// Returns true when at least one element matches `selector` in the HTML string.
func htmlContains(_ selector: String, in html: String) throws -> Bool {
    let doc = try SwiftSoup.parse(html)
    return try doc.select(selector).isEmpty() == false
}

/// Returns the text content of the first element matching `selector`, or nil if not found.
func firstElementText(_ selector: String, in html: String) throws -> String? {
    let doc = try SwiftSoup.parse(html)
    return try doc.select(selector).first()?.text()
}

/// Returns the attribute value of the first element matching `selector`.
func firstAttribute(_ attr: String, ofSelector selector: String, in html: String) throws -> String? {
    let doc = try SwiftSoup.parse(html)
    return try doc.select(selector).first()?.attr(attr)
}

// MARK: - Translation snapshot helpers

/// Runs the full translation segmentation pipeline on an HTML fragment.
func translationSnapshot(html: String, entryId: Int64 = 1) throws -> TranslationSourceSegmentsSnapshot {
    let markdown = try convertMarkdown(html)
    return try TranslationSegmentExtractor.extract(entryId: entryId, markdown: markdown)
}
