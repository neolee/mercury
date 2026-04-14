import Foundation
import Testing
@testable import Mercury

@Suite("Agent Prompt Resolver")
@MainActor
struct AgentPromptResolverTests {
    @Test("Translation standard strategy resolves default built-in template")
    func translationStandardStrategyUsesDefaultBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-standard-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let resolved = try AgentPromptResolver.loadTemplate(
            context: .translation(strategy: .standard),
            appSupportDirectoryOverride: appSupport,
            builtInTemplatesDirectoryOverride: builtIns
        )

        #expect(resolved.template.id == "translation.default")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
    }

    @Test("Translation HY-MT strategy resolves HY-MT built-in template")
    func translationHYMTStrategyUsesHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let resolved = try AgentPromptResolver.loadTemplate(
            context: .translation(strategy: .hyMTOptimized),
            appSupportDirectoryOverride: appSupport,
            builtInTemplatesDirectoryOverride: builtIns
        )

        #expect(resolved.template.id == "translation.hy-mt")
    #expect(resolved.rejectedCustomTemplate?.reason == nil)
    }

    @Test("Translation HY-MT custom seed copies HY-MT built-in with normalized custom template ID")
    func translationHYMTCustomSeedUsesHYMTBuiltInContent() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-seed-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let customURL = try AgentPromptResolver.ensureCustomTemplateFile(
            context: .translation(strategy: .hyMTOptimized),
            appSupportDirectoryOverride: appSupport,
            builtInTemplatesDirectoryOverride: builtIns
        )

        let content = try String(contentsOf: customURL, encoding: .utf8)
        #expect(content.contains("id: translation.default"))
        #expect(content.contains("HY {{targetLanguageDisplayName}}:"))
        #expect(content.contains("id: translation.hy-mt") == false)
    }

    @Test("Valid custom translation template overrides HY-MT built-in")
    func validCustomTemplateOverridesBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-custom-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let customURL = try AgentPromptCustomization.customTemplateFileURL(
            config: .translation,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        try makeTemplate(
            id: "translation.default",
            version: "v4",
            taskType: .translation,
            body: "Custom translation {{targetLanguageDisplayName}}:\n{{sourceText}}"
        ).write(to: customURL, atomically: true, encoding: .utf8)

        let resolved = try AgentPromptResolver.loadTemplate(
            context: .translation(strategy: .hyMTOptimized),
            appSupportDirectoryOverride: appSupport,
            builtInTemplatesDirectoryOverride: builtIns
        )

        #expect(resolved.template.id == "translation.default")
        #expect(try resolved.template.render(parameters: ["sourceText": "x", "targetLanguageDisplayName": "Chinese"]) == "Custom translation Chinese:\nx")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
    }

    @Test("Version-mismatched custom translation template falls back to HY-MT built-in")
    func versionMismatchFallsBackToHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-version-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let customURL = try AgentPromptCustomization.customTemplateFileURL(
            config: .translation,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        try makeTemplate(
            id: "translation.default",
            version: "v3",
            taskType: .translation,
            body: "Custom translation {{targetLanguageDisplayName}}:\n{{sourceText}}"
        ).write(to: customURL, atomically: true, encoding: .utf8)

        let resolved = try AgentPromptResolver.loadTemplate(
            context: .translation(strategy: .hyMTOptimized),
            appSupportDirectoryOverride: appSupport,
            builtInTemplatesDirectoryOverride: builtIns
        )

        #expect(resolved.template.id == "translation.hy-mt")
        #expect(
            resolved.rejectedCustomTemplate?.reason
                == .versionMismatch(customVersion: "v3", builtInVersion: "v4")
        )
    }

    private func makeBuiltInTemplatesDirectory() throws -> URL {
        let directory = try makeTemporaryDirectory(prefix: "resolver-builtins")
        try makeTemplate(
            id: "summary.default",
            version: "v2",
            taskType: .summary,
            body: "Summary:\n{{sourceText}}",
            fileName: "summary.default.yaml",
            directory: directory
        )
        try makeTemplate(
            id: "translation.default",
            version: "v4",
            taskType: .translation,
            body: "Standard {{targetLanguageDisplayName}}:\n{{sourceText}}",
            fileName: "translation.default.yaml",
            directory: directory
        )
        try makeTemplate(
            id: "translation.hy-mt",
            version: "v4",
            taskType: .translation,
            body: "HY {{targetLanguageDisplayName}}:\n{{sourceText}}",
            fileName: "translation.hy-mt.yaml",
            directory: directory
        )
        try makeTemplate(
            id: "tagging.default",
            version: "v2",
            taskType: .tagging,
            body: "Tagging:\n{{body}}",
            fileName: "tagging.default.yaml",
            directory: directory
        )
        return directory
    }

    @discardableResult
    private func makeTemplate(
        id: String,
        version: String,
        taskType: AgentTaskType,
        body: String,
        fileName: String? = nil,
        directory: URL? = nil
    ) throws -> String {
        let requiredPlaceholders: String
        switch taskType {
        case .summary:
            requiredPlaceholders = "  - sourceText"
        case .translation:
            requiredPlaceholders = "  - targetLanguageDisplayName\n  - sourceText"
        case .tagging:
            requiredPlaceholders = "  - body"
        }

        let content = """
        id: \(id)
        version: \(version)
        taskType: \(taskType.rawValue)
        requiredPlaceholders:
        \(requiredPlaceholders)
        template: |
          \(body.replacingOccurrences(of: "\n", with: "\n  "))
        """

        if let directory, let fileName {
            try content.write(
                to: directory.appendingPathComponent(fileName),
                atomically: true,
                encoding: .utf8
            )
        }
        return content
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}