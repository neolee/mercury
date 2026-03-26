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
    let url: URL?
    let html: String?
    let baseURL: URL?
    let onActionURL: ((URL) -> Bool)?

    init(url: URL) {
        self.url = url
        self.html = nil
        self.baseURL = nil
        self.onActionURL = nil
    }

    init(html: String, baseURL: URL?, onActionURL: ((URL) -> Bool)? = nil) {
        self.url = nil
        self.html = html
        self.baseURL = baseURL
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

        guard let url else {
            nsView.loadHTMLString("", baseURL: nil)
            return
        }

        if nsView.url != url {
            nsView.load(URLRequest(url: url))
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var lastBaseStyleContent: String?
        var hasLoadedHTML = false
        var onActionURL: ((URL) -> Bool)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.allow)
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
