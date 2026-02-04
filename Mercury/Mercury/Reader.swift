//
//  ReaderHTMLRenderer.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation
import Down

struct ReaderHTMLRenderer {
    static func render(markdown: String, themeId: String) throws -> String {
        let down = Down(markdownString: markdown)
        let body = try down.toHTML()
        let css = cssForTheme(themeId)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
          <style>
          \(css)
          </style>
        </head>
        <body>
          <article class=\"reader\">
          \(body)
          </article>
        </body>
        </html>
        """
    }

    private static func cssForTheme(_ themeId: String) -> String {
        switch themeId {
        case "dark":
            return baseCSS + "\n" + darkCSS
        case "sepia":
            return baseCSS + "\n" + sepiaCSS
        default:
            return baseCSS
        }
    }

    private static let baseCSS = """
    :root {
      color-scheme: light dark;
    }
    body {
      margin: 0;
      padding: 24px 28px 40px;
      font-family: -apple-system, system-ui, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
      font-size: 17px;
      line-height: 1.65;
      color: #1a1a1a;
      background: #ffffff;
    }
    .reader {
      max-width: 760px;
      margin: 0 auto;
    }
    p {
      margin: 0 0 1em;
    }
    h1, h2, h3, h4, h5, h6 {
      line-height: 1.25;
      margin: 1.6em 0 0.6em;
    }
    img {
      max-width: 100%;
      height: auto;
    }
    blockquote {
      margin: 1.2em 0;
      padding-left: 1em;
      border-left: 3px solid #ddd;
      color: #555;
    }
    code, pre {
      font-family: "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    }
    pre {
      background: #f6f6f6;
      padding: 12px 14px;
      overflow-x: auto;
      border-radius: 8px;
    }
    """

    private static let darkCSS = """
    body {
      color: #e6e6e6;
      background: #121212;
    }
    blockquote {
      border-left-color: #333;
      color: #bdbdbd;
    }
    pre {
      background: #1e1e1e;
    }
    """

    private static let sepiaCSS = """
    body {
      color: #3b2f24;
      background: #f5efe6;
    }
    blockquote {
      border-left-color: #d3c3b4;
      color: #6b5b4b;
    }
    pre {
      background: #efe5d8;
    }
    """
}
