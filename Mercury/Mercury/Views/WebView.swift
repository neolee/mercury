//
//  WebView.swift
//  Mercury
//
//  Created by Neo on 2026/2/3.
//

import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL?
    let html: String?
    let baseURL: URL?

    init(url: URL) {
        self.url = url
        self.html = nil
        self.baseURL = nil
    }

    init(html: String, baseURL: URL?) {
        self.url = nil
        self.html = html
        self.baseURL = baseURL
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.setValue(false, forKey: "drawsBackground")

        if let html {
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                if context.coordinator.hasLoadedHTML,
                   let patch = ReaderHTMLPatch.make(from: html) {
                    applyReaderPatch(
                        patch,
                        to: nsView,
                        fallbackHTML: html,
                        baseURL: baseURL
                    )
                } else {
                    context.coordinator.hasLoadedHTML = true
                    nsView.loadHTMLString(html, baseURL: baseURL)
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

    final class Coordinator {
        var lastHTML: String?
        var hasLoadedHTML = false
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

    private func javaScriptLiteral(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return nil
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }
}

private struct ReaderHTMLPatch {
    let articleInnerHTML: String
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

        let styleRange = html.range(
            of: #"<style>[\s\S]*?mercury-translation-block[\s\S]*?</style>"#,
            options: .regularExpression
        )
        let translationStyle: String?
        if let styleRange {
            let styleBlock = String(html[styleRange])
            translationStyle = styleBlock
                .replacingOccurrences(of: "<style>", with: "")
                .replacingOccurrences(of: "</style>", with: "")
        } else {
            translationStyle = nil
        }

        return ReaderHTMLPatch(
            articleInnerHTML: articleInner,
            translationStyle: translationStyle
        )
    }
}
