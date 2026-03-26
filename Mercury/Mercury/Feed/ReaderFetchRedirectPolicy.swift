//
//  ReaderFetchRedirectPolicy.swift
//  Mercury
//

import Foundation

enum ReaderFetchRedirectPolicy {
    static func upgradedRedirectRequest(
        originalURL: URL?,
        redirectRequest: URLRequest
    ) -> URLRequest? {
        guard let redirectURL = redirectRequest.url,
              let upgradedURL = upgradedRedirectURL(
                originalURL: originalURL,
                redirectURL: redirectURL
              ) else {
            return nil
        }

        var upgradedRequest = redirectRequest
        upgradedRequest.url = upgradedURL
        return upgradedRequest
    }

    static func upgradedRedirectURL(originalURL: URL?, redirectURL: URL?) -> URL? {
        guard let originalURL,
              let redirectURL,
              originalURL.scheme?.lowercased() == "https",
              redirectURL.scheme?.lowercased() == "http",
              let originalHost = originalURL.host?.lowercased(),
              let redirectHost = redirectURL.host?.lowercased(),
              originalHost == redirectHost else {
            return nil
        }

        var components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        if components?.port == 80 {
            components?.port = nil
        }
        return components?.url
    }
}
