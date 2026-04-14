//
//  WebView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import Foundation
import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let request: WebRequest?
    let html: String?
    let baseURL: URL?
    let navigationID: Int64?
    let onActionURL: ((URL) -> Bool)?

    init(request: WebRequest, navigationID: Int64?) {
        self.request = request
        self.html = nil
        self.baseURL = nil
        self.navigationID = navigationID
        self.onActionURL = nil
    }

    init(html: String, baseURL: URL?, onActionURL: ((URL) -> Bool)? = nil) {
        self.request = nil
        self.html = html
        self.baseURL = baseURL
        self.navigationID = nil
        self.onActionURL = onActionURL
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.onActionURL = onActionURL
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.setValue(false, forKey: "drawsBackground")
        context.coordinator.onActionURL = onActionURL

        if let html {
            context.coordinator.lastInitiatedTopLevelRequest = nil
            context.coordinator.lastNavigationID = nil
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                let patch = ReaderHTMLPatch.make(from: html)
                if Self.shouldApplyReaderPatch(
                    hasLoadedHTML: context.coordinator.hasLoadedHTML,
                    previousBaseStyleContent: context.coordinator.lastBaseStyleContent,
                    patch: patch
                ),
                   let patch {
                    applyReaderPatch(
                        patch,
                        to: nsView,
                        fallbackHTML: html,
                        baseURL: baseURL
                    )
                } else {
                    loadFullHTML(
                        html,
                        patch: patch,
                        into: nsView,
                        coordinator: context.coordinator,
                        baseURL: baseURL
                    )
                }
            }
            return
        }

        guard let request else {
            context.coordinator.lastInitiatedTopLevelRequest = nil
            context.coordinator.lastNavigationID = nil
            nsView.loadHTMLString("", baseURL: nil)
            return
        }

        let shouldLoad = Self.shouldLoadRequestedURL(
            lastNavigationID: context.coordinator.lastNavigationID,
            requestedNavigationID: navigationID,
            lastInitiatedRequest: context.coordinator.lastInitiatedTopLevelRequest,
            requestedRequest: request
        )
        if shouldLoad {
            if nsView.isLoading {
                nsView.stopLoading()
            }
            context.coordinator.lastNavigationID = navigationID
            context.coordinator.lastInitiatedTopLevelRequest = request
            _ = nsView.load(URLRequest(url: request.url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func shouldApplyReaderPatch(
        hasLoadedHTML: Bool,
        previousBaseStyleContent: String?,
        patch: ReaderHTMLPatch?
    ) -> Bool {
        guard hasLoadedHTML,
              let patch else {
            return false
        }

        return patch.baseStyleContent == previousBaseStyleContent
    }

    static func shouldLoadRequestedURL(
        lastNavigationID: Int64?,
        requestedNavigationID: Int64?,
        lastInitiatedRequest: WebRequest?,
        requestedRequest: WebRequest
    ) -> Bool {
        if lastNavigationID != requestedNavigationID {
            return true
        }
        guard let lastInitiatedRequest else {
            return true
        }
        return WebNavigationPolicy.shouldReloadTopLevelRequest(
            lastRequest: lastInitiatedRequest,
            requestedRequest: requestedRequest
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var lastBaseStyleContent: String?
        var hasLoadedHTML = false
        var lastNavigationID: Int64?
        var lastInitiatedTopLevelRequest: WebRequest?
        var onActionURL: ((URL) -> Bool)?

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != false,
               let upgradedRequest = ReaderFetchRedirectPolicy.upgradedRedirectRequest(
                originalURL: lastInitiatedTopLevelRequest?.url,
                redirectRequest: navigationAction.request
               ),
               let upgradedURL = upgradedRequest.url,
               upgradedURL != requestURL {
                lastInitiatedTopLevelRequest = WebRequest(
                    url: upgradedURL,
                    source: lastInitiatedTopLevelRequest?.source ?? .entryFallback
                )
                decisionHandler(.cancel)
                _ = webView.load(upgradedRequest)
                return
            }
            if let onActionURL,
               onActionURL(requestURL) {
                decisionHandler(.cancel)
                return
            }
            if requestURL.scheme?.lowercased() == "mercury-action" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private func applyReaderPatch(
        _ patch: ReaderHTMLPatch,
        to webView: WKWebView,
        fallbackHTML: String,
        baseURL: URL?
    ) {
        guard let articleJS = javaScriptLiteral(patch.articleInnerHTML) else {
            webView.loadHTMLString(fallbackHTML, baseURL: baseURL)
            return
        }

        let styleJS: String
        if let translationStyle = patch.translationStyle,
           let styleLiteral = javaScriptLiteral(translationStyle) {
            styleJS = styleLiteral
        } else {
            styleJS = "null"
        }

        let script = """
        (function () {
          const article = document.querySelector('article.reader');
          if (!article) { return false; }
                    const scrollX = window.scrollX;
                    const scrollY = window.scrollY;
                    const root = document.documentElement;
                    const previousScrollBehavior = root.style.scrollBehavior;
                    root.style.scrollBehavior = 'auto';

          article.innerHTML = \(articleJS);

          const styleContent = \(styleJS);
          if (styleContent !== null) {
            let style = document.getElementById('mercury-translation-style');
            if (!style) {
              style = document.createElement('style');
              style.id = 'mercury-translation-style';
              document.head.appendChild(style);
            }
            style.textContent = styleContent;
          }

                    window.scrollTo(scrollX, scrollY);
                    root.style.scrollBehavior = previousScrollBehavior;
          return true;
        })();
        """

        webView.evaluateJavaScript(script) { result, _ in
            if let applied = result as? Bool, applied {
                return
            }
            webView.loadHTMLString(fallbackHTML, baseURL: baseURL)
        }
    }

    private func loadFullHTML(
        _ html: String,
        patch: ReaderHTMLPatch?,
        into webView: WKWebView,
        coordinator: Coordinator,
        baseURL: URL?
    ) {
        coordinator.hasLoadedHTML = true
        coordinator.lastBaseStyleContent = patch?.baseStyleContent
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private func javaScriptLiteral(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return nil
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }
}

struct ReaderHTMLPatch {
    let articleInnerHTML: String
    let baseStyleContent: String?
    let translationStyle: String?

    static func make(from html: String) -> ReaderHTMLPatch? {
        guard let articleRange = html.range(
            of: #"<article\s+class=\"reader\">([\s\S]*?)</article>"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let articleBlock = String(html[articleRange])
        guard let innerRange = articleBlock.range(
            of: #"^<article\s+class=\"reader\">([\s\S]*?)</article>$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let innerBlock = String(articleBlock[innerRange])
        let prefix = #"<article class=\"reader\">"#
        let suffix = "</article>"
        let articleInner = innerBlock
            .replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: suffix, with: "")

        let styleBlocks = extractStyleBlocks(from: html)

        return ReaderHTMLPatch(
            articleInnerHTML: articleInner,
            baseStyleContent: styleBlocks.baseStyleContent,
            translationStyle: styleBlocks.translationStyle
        )
    }

    private static func extractStyleBlocks(from html: String) -> (baseStyleContent: String?, translationStyle: String?) {
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let regex = try? NSRegularExpression(
            pattern: #"<style>([\s\S]*?)</style>"#,
            options: []
        ) else {
            return (nil, nil)
        }

        let matches = regex.matches(in: html, options: [], range: nsRange)
        var baseStyleContent: String?
        var translationStyle: String?

        for match in matches {
            guard match.numberOfRanges >= 2,
                  let contentRange = Range(match.range(at: 1), in: html) else {
                continue
            }

            let styleContent = String(html[contentRange])
            if styleContent.contains("mercury-translation-block") {
                translationStyle = styleContent
            } else if baseStyleContent == nil {
                baseStyleContent = styleContent
            }
        }

        return (baseStyleContent, translationStyle)
    }
}
