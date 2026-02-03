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
    func parse(url: URL, limit: Int) throws -> [OPMLFeed] {
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
    private let limit: Int
    private(set) var results: [OPMLFeed] = []

    init(limit: Int) {
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
        guard results.count < limit else { return }

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
