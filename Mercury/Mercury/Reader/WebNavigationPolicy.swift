import Foundation

enum WebRequestSource: String, Sendable {
    case entryFallback
    case documentBase

    var priority: Int {
        switch self {
        case .entryFallback:
            return 0
        case .documentBase:
            return 1
        }
    }
}

struct WebRequest: Equatable, Sendable {
    let url: URL
    let source: WebRequestSource
}

enum WebNavigationPolicy {
    static func fallbackRequest(entryURL: URL) -> WebRequest {
        WebRequest(
            url: URLHTTPSUpgrade.preferredHTTPSURL(from: entryURL),
            source: .entryFallback
        )
    }

    static func preferredRequest(entryURL: URL, documentBaseURL: URL?) -> WebRequest {
        let fallbackRequest = fallbackRequest(entryURL: entryURL)
        guard let documentBaseURL,
              canUseDocumentBaseURLForNavigation(entryURL: entryURL, documentBaseURL: documentBaseURL) else {
            return fallbackRequest
        }
        return WebRequest(url: documentBaseURL, source: .documentBase)
    }

    static func areEquivalentTopLevelNavigationURLs(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs == rhs {
            return true
        }

        return normalizedIssuedRequestIdentity(for: lhs) == normalizedIssuedRequestIdentity(for: rhs)
    }

    static func shouldReloadTopLevelRequest(lastRequest: WebRequest, requestedRequest: WebRequest) -> Bool {
        guard areEquivalentTopLevelNavigationURLs(lastRequest.url, requestedRequest.url) else {
            return true
        }

        return requestedRequest.source.priority > lastRequest.source.priority
    }

    private static func canUseDocumentBaseURLForNavigation(entryURL: URL, documentBaseURL: URL) -> Bool {
        normalizedNavigationTargetIdentity(for: entryURL) == normalizedNavigationTargetIdentity(for: documentBaseURL)
    }

    private static func normalizedNavigationTargetIdentity(for url: URL) -> NormalizedNavigationIdentity? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }

        let normalizedScheme = "https"
        let normalizedPath = normalizePath(url.path)
        let port = normalizedPort(for: url.port, scheme: scheme)

        return NormalizedNavigationIdentity(
            scheme: normalizedScheme,
            host: host,
            port: port,
            path: normalizedPath,
            query: url.query,
            fragment: url.fragment
        )
    }

    private static func normalizedIssuedRequestIdentity(for url: URL) -> NormalizedNavigationIdentity? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }

        let normalizedPath = normalizePath(url.path)
        let port = normalizedPort(for: url.port, scheme: scheme)

        return NormalizedNavigationIdentity(
            scheme: scheme,
            host: host,
            port: port,
            path: normalizedPath,
            query: url.query,
            fragment: url.fragment
        )
    }

    private static func normalizedPort(for port: Int?, scheme: String) -> Int? {
        guard let port else {
            return nil
        }

        if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            return nil
        }

        return port
    }

    private static func normalizePath(_ path: String) -> String {
        guard path.count > 1 else {
            return path
        }

        var normalizedPath = path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return normalizedPath
    }
}

private struct NormalizedNavigationIdentity: Equatable {
    let scheme: String
    let host: String
    let port: Int?
    let path: String
    let query: String?
    let fragment: String?
}
