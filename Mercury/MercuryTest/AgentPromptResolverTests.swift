import Foundation
import Testing
@testable import Mercury

@Suite("Agent Prompt Resolver")
@MainActor
struct AgentPromptResolverTests {
    @Test("Translation default variant resolves default built-in template")
    func translationDefaultVariantUsesDefaultBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-standard-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let resolved = try loadTemplate(descriptor: .translationDefault, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.default")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
    }

    @Test("Translation HY-MT variant resolves HY-MT built-in template")
    func translationHYMTVariantUsesHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let resolved = try loadTemplate(descriptor: .translationHYMT, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.hy-mt")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
    }

    @Test("Standard custom seed copies the default built-in without rewriting its ID")
    func standardCustomSeedCopiesDefaultBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-standard-seed-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let builtInURL = builtIns.appendingPathComponent("translation.default.yaml")
        let customURL = try AgentPromptResolver.ensureCustomTemplateFile(
            descriptor: .translationDefault,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(customURL.lastPathComponent == "translation.default.yaml")
        let builtInContent = try String(contentsOf: builtInURL, encoding: .utf8)
        let customContent = try String(contentsOf: customURL, encoding: .utf8)
        #expect(customContent == builtInContent)
        #expect(customContent.contains("id: translation.default"))
    }

    @Test("HY-MT custom seed copies the HY-MT built-in without rewriting its ID")
    func translationHYMTCustomSeedCopiesHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-seed-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let builtInURL = builtIns.appendingPathComponent("translation.hy-mt.yaml")
        let customURL = try AgentPromptResolver.ensureCustomTemplateFile(
            descriptor: .translationHYMT,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtInURL
        )

        #expect(customURL.lastPathComponent == "translation.hy-mt.yaml")
        let builtInContent = try String(contentsOf: builtInURL, encoding: .utf8)
        let customContent = try String(contentsOf: customURL, encoding: .utf8)
        #expect(customContent == builtInContent)
        #expect(customContent.contains("id: translation.hy-mt"))
        #expect(customContent.contains("id: translation.default") == false)
    }

    @Test("Standard custom file does not override the HY-MT built-in")
    func standardCustomFileDoesNotOverrideHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-standard-isolation-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        try writeCustomTemplate(
            descriptor: .translationDefault,
            version: "v4",
            body: "Custom standard {{targetLanguageDisplayName}}:\n{{sourceText}}",
            appSupport: appSupport
        )

        let resolved = try loadTemplate(descriptor: .translationHYMT, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.hy-mt")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
        #expect(
            try resolved.template.render(
                parameters: ["sourceText": "x", "targetLanguageDisplayName": "Chinese"]
            ) == "HY Chinese:\nx"
        )
    }

    @Test("HY-MT custom file does not override the standard built-in")
    func hyMTCustomFileDoesNotOverrideStandardBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-isolation-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        try writeCustomTemplate(
            descriptor: .translationHYMT,
            version: "v4",
            body: "Custom HY {{targetLanguageDisplayName}}:\n{{sourceText}}",
            appSupport: appSupport
        )

        let resolved = try loadTemplate(descriptor: .translationDefault, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.default")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
        #expect(
            try resolved.template.render(
                parameters: ["sourceText": "x", "targetLanguageDisplayName": "Chinese"]
            ) == "Standard Chinese:\nx"
        )
    }

    @Test("Valid standard custom template overrides the standard built-in")
    func validStandardCustomTemplateOverridesStandardBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-standard-custom-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        try writeCustomTemplate(
            descriptor: .translationDefault,
            version: "v4",
            body: "Validated standard {{targetLanguageDisplayName}}:\n{{sourceText}}",
            appSupport: appSupport
        )

        let resolved = try loadTemplate(descriptor: .translationDefault, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.default")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
        #expect(
            try resolved.template.render(
                parameters: ["sourceText": "x", "targetLanguageDisplayName": "Chinese"]
            ) == "Validated standard Chinese:\nx"
        )
    }

    @Test("Valid HY-MT custom template overrides the HY-MT built-in")
    func validHYMTCustomTemplateOverridesHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-custom-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        try writeCustomTemplate(
            descriptor: .translationHYMT,
            version: "v4",
            body: "Validated HY {{targetLanguageDisplayName}}:\n{{sourceText}}",
            appSupport: appSupport
        )

        let resolved = try loadTemplate(descriptor: .translationHYMT, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.hy-mt")
        #expect(resolved.rejectedCustomTemplate?.reason == nil)
        #expect(
            try resolved.template.render(
                parameters: ["sourceText": "x", "targetLanguageDisplayName": "Chinese"]
            ) == "Validated HY Chinese:\nx"
        )
    }

    @Test("Version-mismatched HY-MT custom template falls back to the HY-MT built-in")
    func versionMismatchFallsBackToHYMTBuiltIn() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-hymt-version-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        try writeCustomTemplate(
            descriptor: .translationHYMT,
            version: "v3",
            body: "Versioned HY {{targetLanguageDisplayName}}:\n{{sourceText}}",
            appSupport: appSupport
        )

        let resolved = try loadTemplate(descriptor: .translationHYMT, builtIns: builtIns, appSupport: appSupport)

        #expect(resolved.template.id == "translation.hy-mt")
        #expect(
            resolved.rejectedCustomTemplate?.reason
                == .versionMismatch(customVersion: "v3", builtInVersion: "v4")
        )
    }

    @Test("Legacy translation.yaml is ignored by both translation variants")
    func legacyTranslationYAMLIsIgnored() throws {
        let builtIns = try makeBuiltInTemplatesDirectory()
        let appSupport = try makeTemporaryDirectory(prefix: "resolver-legacy-appsupport")
        defer {
            try? FileManager.default.removeItem(at: builtIns)
            try? FileManager.default.removeItem(at: appSupport)
        }

        let standardURL = try AgentPromptCustomization.customTemplateFileURL(
            descriptor: .translationDefault,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        let legacyURL = standardURL
            .deletingLastPathComponent()
            .appendingPathComponent("translation.yaml")
        try makeTemplate(
            id: "translation.default",
            version: "v4",
            taskType: .translation,
            body: "Legacy custom {{targetLanguageDisplayName}}:\n{{sourceText}}"
        ).write(to: legacyURL, atomically: true, encoding: .utf8)

        let standardResolved = try loadTemplate(descriptor: .translationDefault, builtIns: builtIns, appSupport: appSupport)
        let hyMTResolved = try loadTemplate(descriptor: .translationHYMT, builtIns: builtIns, appSupport: appSupport)

        #expect(standardResolved.template.id == "translation.default")
        #expect(standardResolved.rejectedCustomTemplate?.reason == nil)
        #expect(hyMTResolved.template.id == "translation.hy-mt")
        #expect(hyMTResolved.rejectedCustomTemplate?.reason == nil)
    }

    private func loadTemplate(
        descriptor: AgentPromptTemplateDescriptor,
        builtIns: URL,
        appSupport: URL
    ) throws -> TemplateCustomizationLoadResult<AgentPromptTemplate> {
        try AgentPromptResolver.loadTemplate(
            descriptor: descriptor,
            appSupportDirectoryOverride: appSupport,
            builtInTemplateURLOverride: builtIns.appendingPathComponent("\(descriptor.builtInTemplateName).yaml")
        )
    }

    private func writeCustomTemplate(
        descriptor: AgentPromptTemplateDescriptor,
        version: String,
        body: String,
        appSupport: URL
    ) throws {
        let customURL = try AgentPromptCustomization.customTemplateFileURL(
            descriptor: descriptor,
            appSupportDirectoryOverride: appSupport,
            createDirectoryIfNeeded: true
        )
        try makeTemplate(
            id: descriptor.templateID,
            version: version,
            taskType: descriptor.agent,
            body: body
        ).write(to: customURL, atomically: true, encoding: .utf8)
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
