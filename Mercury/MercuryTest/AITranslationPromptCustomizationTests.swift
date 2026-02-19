import Foundation
import Testing
@testable import Mercury

@Suite("AI Translation Prompt Customization")
struct AITranslationPromptCustomizationTests {
    @Test("Create custom translation template from built-in when missing")
    func createCustomTemplateWhenMissing() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-translation-prompts-appsupport")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-translation-prompts-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let builtInURL = builtInDirectory.appendingPathComponent("translation.default.yaml")
        let builtInContent = makeTemplate(version: "builtin-v1")
        try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

        let destination = try AITranslationPromptCustomization.ensureCustomTemplateFile(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(fileManager.fileExists(atPath: destination.path))
        let copied = try String(contentsOf: destination, encoding: .utf8)
        #expect(copied == builtInContent)
    }

    @Test("Prefer custom translation template when present")
    func preferCustomTemplateWhenPresent() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-translation-prompts-prefer-custom")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-translation-prompts-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let customURL = try AITranslationPromptCustomization.customTemplateFileURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        try makeTemplate(version: "custom-v9")
            .write(to: customURL, atomically: true, encoding: .utf8)

        let builtInURL = builtInDirectory.appendingPathComponent("translation.default.yaml")
        try makeTemplate(version: "builtin-v3")
            .write(to: builtInURL, atomically: true, encoding: .utf8)

        let template = try AITranslationPromptCustomization.loadTranslationTemplate(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(template.version == "custom-v9")
    }

    @Test("Fallback to built-in translation template when custom is absent")
    func fallbackToBuiltInTemplateWhenCustomMissing() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-translation-prompts-fallback-appsupport")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-translation-prompts-fallback-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let builtInURL = builtInDirectory.appendingPathComponent("translation.default.yaml")
        try makeTemplate(version: "builtin-v7")
            .write(to: builtInURL, atomically: true, encoding: .utf8)

        let template = try AITranslationPromptCustomization.loadTranslationTemplate(
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
        id: translation.default
        version: \(version)
        taskType: translation
        template: |
          Translate to {{targetLanguageDisplayName}}.
          {{sourceSegmentsJSON}}
        """
    }
}
