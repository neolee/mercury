//
//  ReaderHTMLRenderer.swift
//  Mercury
//
//  Created by Neo on 2026/2/4.
//

import Foundation
import Down

struct ReaderHTMLRenderer {
    static func render(markdown: String, theme: EffectiveReaderTheme) throws -> String {
        let down = Down(markdownString: markdown)
        let body = try down.toHTML()
        let css = css(for: theme.tokens)

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
          \(css)
          </style>
        </head>
        <body>
          <article class="reader">
          \(body)
          </article>
        </body>
        </html>
        """
    }

    static func render(markdown: String, themeId: String) throws -> String {
        let legacyTheme: EffectiveReaderTheme
        switch themeId {
        case "dark":
            legacyTheme = ReaderThemeResolver.resolve(
                presetID: .classic,
                mode: .forceDark,
                isSystemDark: false,
                override: nil
            )
        case "sepia":
            legacyTheme = ReaderThemeResolver.resolve(
                presetID: .paper,
                mode: .forceLight,
                isSystemDark: false,
                override: nil
            )
        default:
            legacyTheme = ReaderThemeResolver.resolve(
                presetID: .classic,
                mode: .forceLight,
                isSystemDark: false,
                override: nil
            )
        }

        return try render(markdown: markdown, theme: legacyTheme)
    }

    private static func css(for tokens: ReaderThemeTokens) -> String {
        """
        :root {
          color-scheme: light dark;
        }
        body {
          margin: 0;
          padding: 24px 28px 40px;
          font-family: \(tokens.fontFamilyBody);
          font-size: \(tokens.fontSizeBody)px;
          line-height: \(tokens.lineHeightBody);
          color: \(tokens.colorTextPrimary);
          background: \(tokens.colorBackground);
        }
        .reader {
          max-width: \(tokens.contentMaxWidth)px;
          margin: 0 auto;
        }
        p {
          margin: 0 0 \(tokens.paragraphSpacing)em;
        }
        h1, h2, h3, h4, h5, h6 {
          line-height: \(1.25 * tokens.headingScale);
          margin: 1.6em 0 0.6em;
        }
        img {
          max-width: 100%;
          height: auto;
        }
        blockquote {
          margin: 1.2em 0;
          padding-left: 1em;
          border-left: 3px solid \(tokens.colorBlockquoteBorder);
          color: \(tokens.colorTextSecondary);
        }
        a {
          color: \(tokens.colorLink);
        }
        code, pre {
          font-family: "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        }
        pre {
          background: \(tokens.colorCodeBackground);
          padding: 12px 14px;
          overflow-x: auto;
          border-radius: \(tokens.codeBlockRadius)px;
        }
        """
    }
}
