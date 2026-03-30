import Foundation
import Testing
@testable import Mercury

@Suite("Digest Template Customization")
struct DigestTemplateCustomizationTests {
    @Test("Create custom digest template from built-in when missing for all digest outputs")
    func createCustomTemplateWhenMissing() throws {
        for digest in digestCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-appsupport")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let builtInURL = builtInDirectory.appendingPathComponent("\(digest.config.customization.builtInTemplateName).yaml")
            let builtInContent = digest.makeTemplate(version: "builtin-v1")
            try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

            let destination = try DigestTemplateCustomization.ensureCustomTemplateFile(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(fileManager.fileExists(atPath: destination.path))
            #expect(destination.lastPathComponent == digest.config.customization.customTemplateFileName)
            let copied = try String(contentsOf: destination, encoding: .utf8)
            #expect(copied == builtInContent)
        }
    }

    @Test("Skip copy when custom digest template already exists for all digest outputs")
    func skipCopyWhenCustomTemplateExists() throws {
        for digest in digestCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-existing")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-existing-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let existingCustomURL = try DigestTemplateCustomization.customTemplateFileURL(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            let existingContent = digest.makeTemplate(version: "custom-existing")
            try existingContent.write(to: existingCustomURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(digest.config.customization.builtInTemplateName).yaml")
            try digest.makeTemplate(version: "builtin-v2").write(to: builtInURL, atomically: true, encoding: .utf8)

            let resolved = try DigestTemplateCustomization.ensureCustomTemplateFile(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(resolved.path == existingCustomURL.path)
            let currentContent = try String(contentsOf: resolved, encoding: .utf8)
            #expect(currentContent == existingContent)
        }
    }

    @Test("Prefer custom digest template when present for all digest outputs")
    func preferCustomTemplateWhenPresent() throws {
        for digest in digestCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-custom")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-custom-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try DigestTemplateCustomization.customTemplateFileURL(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try digest.makeTemplate(version: "custom-v9").write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(digest.config.customization.builtInTemplateName).yaml")
            try digest.makeTemplate(version: "builtin-v3").write(to: builtInURL, atomically: true, encoding: .utf8)

            let template = try DigestTemplateCustomization.loadTemplate(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(template.id == digest.config.templateID)
            #expect(template.version == "custom-v9")
        }
    }

    @Test("Fallback to built-in digest template when custom template is invalid for all digest outputs")
    func fallbackToBuiltInTemplateWhenCustomInvalid() throws {
        for digest in digestCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-invalid")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-invalid-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try DigestTemplateCustomization.customTemplateFileURL(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try "not: [valid: yaml".write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(digest.config.customization.builtInTemplateName).yaml")
            try digest.makeTemplate(version: "builtin-v8").write(to: builtInURL, atomically: true, encoding: .utf8)

            var reportedPath: String?
            let template = try DigestTemplateCustomization.loadTemplate(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL,
                onInvalidCustomTemplate: { url, _ in
                    reportedPath = url.path
                }
            )

            #expect(template.version == "builtin-v8")
            #expect(reportedPath == customURL.path)
            #expect(fileManager.fileExists(atPath: customURL.path))
        }
    }

    @Test("Deleting custom digest template restores built-in behavior for all digest outputs")
    func deletingCustomTemplateRestoresBuiltInBehavior() throws {
        for digest in digestCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-reset")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(digest.name)-digest-reset-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try DigestTemplateCustomization.customTemplateFileURL(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try digest.makeTemplate(version: "custom-v5").write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(digest.config.customization.builtInTemplateName).yaml")
            try digest.makeTemplate(version: "builtin-v5").write(to: builtInURL, atomically: true, encoding: .utf8)

            let customized = try DigestTemplateCustomization.loadTemplate(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )
            #expect(customized.version == "custom-v5")

            try fileManager.removeItem(at: customURL)

            let restored = try DigestTemplateCustomization.loadTemplate(
                config: digest.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )
            #expect(restored.version == "builtin-v5")
        }
    }

    private var digestCases: [DigestCustomizationCase] {
        [
            DigestCustomizationCase(name: "share", config: .shareDigest, templateFactory: makeSingleTextTemplate),
            DigestCustomizationCase(name: "export", config: .exportDigest, templateFactory: makeSingleMarkdownTemplate),
            DigestCustomizationCase(name: "export-multiple", config: .exportMultipleDigest, templateFactory: makeMultipleMarkdownTemplate)
        ]
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSingleTextTemplate(version: String) -> String {
        """
        id: single-text
        version: \(version)
        requiredPlaceholders:
          - articleTitle
          - articleURL
        optionalPlaceholders:
          - articleAuthor
        template: |
                    {{articleTitle}} {{articleAuthor}} {{articleURL}}
        """
    }

    private func makeSingleMarkdownTemplate(version: String) -> String {
        """
        id: single-markdown
        version: \(version)
        requiredPlaceholders:
          - exportDateTimeISO8601
          - digestTitle
          - fileSlug
          - articleTitle
          - articleURL
        optionalPlaceholders:
          - articleAuthor
        template: |
          +++
          date = '{{exportDateTimeISO8601}}'
          title = '{{digestTitle}}'
          slug = '{{fileSlug}}'
          +++

          [{{articleTitle}}]({{articleURL}})
                    {{articleAuthor}}
        """
    }

    private func makeMultipleMarkdownTemplate(version: String) -> String {
        """
        id: multiple-markdown
        version: \(version)
        requiredPlaceholders:
          - exportDateTimeISO8601
          - digestTitle
          - fileSlug
          - entries
        optionalPlaceholders:
          - articleTitle
          - articleURL
        repeatedSectionNames:
          - entries
        template: |
          +++
          date = '{{exportDateTimeISO8601}}'
          title = '{{digestTitle}}'
          slug = '{{fileSlug}}'
          +++

          {{#entries}}
          ## {{articleTitle}}
          {{articleURL}}
          {{/entries}}
        """
    }
}

private struct DigestCustomizationCase {
    let name: String
    let config: DigestTemplateCustomizationConfig
    let templateFactory: (String) -> String

    func makeTemplate(version: String) -> String {
        templateFactory(version)
    }
}