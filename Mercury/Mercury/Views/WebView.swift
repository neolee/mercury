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

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let url else {
            nsView.loadHTMLString("", baseURL: nil)
            return
        }

        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
