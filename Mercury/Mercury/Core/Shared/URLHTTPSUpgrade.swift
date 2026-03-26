//
//  URLHTTPSUpgrade.swift
//  Mercury
//

import Foundation

enum URLHTTPSUpgrade {
    nonisolated static func preferredHTTPSURL(from url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        if components?.port == 80 {
            components?.port = nil
        }
        return components?.url ?? url
    }

    nonisolated static func preferredHTTPSURLString(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines),
              scheme.isEmpty == false,
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return preferredHTTPSURL(from: url).absoluteString
    }
}
