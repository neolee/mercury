import Foundation
import Testing
@testable import Mercury

@Suite("AI Summary Prompt Customization")
struct AISummaryPromptCustomizationTests {
    @Test("Create custom template from built-in when missing")
    func createCustomTemplateWhenMissing() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-appsupport")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let builtInURL = builtInDirectory.appendingPathComponent("summary.default.yaml")
        let builtInContent = makeTemplate(version: "builtin-v1")
        try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

        let destination = try AISummaryPromptCustomization.ensureCustomTemplateFile(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(fileManager.fileExists(atPath: destination.path))
        let copied = try String(contentsOf: destination, encoding: .utf8)
        #expect(copied == builtInContent)
    }

    @Test("Skip copy when custom template already exists")
    func skipCopyWhenCustomTemplateExists() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-existing")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-existing-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let existingCustomURL = try AISummaryPromptCustomization.customTemplateFileURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        let existingContent = makeTemplate(version: "custom-existing")
        try existingContent.write(to: existingCustomURL, atomically: true, encoding: .utf8)

        let builtInURL = builtInDirectory.appendingPathComponent("summary.default.yaml")
        let builtInContent = makeTemplate(version: "builtin-v2")
        try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

        let resolved = try AISummaryPromptCustomization.ensureCustomTemplateFile(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(resolved.path == existingCustomURL.path)
        let currentContent = try String(contentsOf: resolved, encoding: .utf8)
        #expect(currentContent == existingContent)
    }

    @Test("Prefer custom template when present")
    func preferCustomTemplateWhenPresent() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-prefer-custom")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-prefer-custom-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let customURL = try AISummaryPromptCustomization.customTemplateFileURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        try makeTemplate(version: "custom-v9")
            .write(to: customURL, atomically: true, encoding: .utf8)

        let builtInURL = builtInDirectory.appendingPathComponent("summary.default.yaml")
        try makeTemplate(version: "builtin-v3")
            .write(to: builtInURL, atomically: true, encoding: .utf8)

        let template = try AISummaryPromptCustomization.loadSummaryTemplate(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(template.version == "custom-v9")
    }

    @Test("Custom template loading ignores sibling yaml files")
    func customTemplateLoadingIgnoresSiblingYAML() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-sibling")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-sibling-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let customURL = try AISummaryPromptCustomization.customTemplateFileURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        try makeTemplate(version: "custom-v11")
            .write(to: customURL, atomically: true, encoding: .utf8)

        let siblingURL = customURL
            .deletingLastPathComponent()
            .appendingPathComponent("summary.backup.yaml")
        try makeTemplate(version: "backup-v0")
            .write(to: siblingURL, atomically: true, encoding: .utf8)

        let builtInURL = builtInDirectory.appendingPathComponent("summary.default.yaml")
        try makeTemplate(version: "builtin-v0")
            .write(to: builtInURL, atomically: true, encoding: .utf8)

        let template = try AISummaryPromptCustomization.loadSummaryTemplate(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(template.version == "custom-v11")
    }

    @Test("Fallback to built-in template when custom is absent")
    func fallbackToBuiltInTemplateWhenCustomMissing() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-fallback-appsupport")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-custom-prompts-fallback-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let builtInURL = builtInDirectory.appendingPathComponent("summary.default.yaml")
        try makeTemplate(version: "builtin-v7")
            .write(to: builtInURL, atomically: true, encoding: .utf8)

        let template = try AISummaryPromptCustomization.loadSummaryTemplate(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(template.version == "builtin-v7")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTemplate(version: String) -> String {
        """
        id: summary.default
        version: \(version)
        taskType: summary
        template: |
          Summarize in {{targetLanguageDisplayName}} with {{detailLevel}}.
          {{sourceText}}
        """
    }
}
