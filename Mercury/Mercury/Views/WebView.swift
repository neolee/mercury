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
        if let html {
            nsView.setValue(true, forKey: "drawsBackground")
            if context.coordinator.lastHTML != html {
                context.coordinator.lastHTML = html
                nsView.loadHTMLString(html, baseURL: baseURL)
            }
            return
        }

        nsView.setValue(false, forKey: "drawsBackground")

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
    }
}
