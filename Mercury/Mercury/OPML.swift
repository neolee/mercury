//
//  OPMLImporter.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation

struct OPMLFeed: Hashable {
    let title: String?
    let feedURL: String
    let siteURL: String?
}

final class OPMLImporter: NSObject {
    func parse(url: URL, limit: Int? = nil) throws -> [OPMLFeed] {
        let parser = XMLParser(contentsOf: url)
        let delegate = OPMLParserDelegate(limit: limit)
        parser?.delegate = delegate
        parser?.shouldResolveExternalEntities = false

        guard parser?.parse() == true else {
            throw OPMLImportError.parseFailed
        }

        return delegate.results
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private let limit: Int?
    private(set) var results: [OPMLFeed] = []

    init(limit: Int?) {
        self.limit = limit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName == "outline" else { return }
        if let limit {
            guard results.count < limit else { return }
        }

        if let xmlURL = attributeDict["xmlUrl"], !xmlURL.isEmpty {
            let title = attributeDict["title"] ?? attributeDict["text"]
            let siteURL = attributeDict["htmlUrl"]
            let feed = OPMLFeed(title: title, feedURL: xmlURL, siteURL: siteURL)
            results.append(feed)
        }
    }
}

enum OPMLImportError: Error {
    case parseFailed
}

struct OPMLExporter {
    func export(feeds: [Feed], title: String) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\">")
        lines.append("  <head>")
        lines.append("    <title>\(escape(title))</title>")
        lines.append("  </head>")
        lines.append("  <body>")
        for feed in feeds {
            let text = escape(feed.title ?? feed.feedURL)
            let xmlUrl = escape(feed.feedURL)
            let htmlUrl = escape(feed.siteURL ?? "")
            if htmlUrl.isEmpty {
                lines.append("    <outline text=\"\(text)\" title=\"\(text)\" type=\"rss\" xmlUrl=\"\(xmlUrl)\" />")
            } else {
                lines.append("    <outline text=\"\(text)\" title=\"\(text)\" type=\"rss\" xmlUrl=\"\(xmlUrl)\" htmlUrl=\"\(htmlUrl)\" />")
            }
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
