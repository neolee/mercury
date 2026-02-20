import Foundation
import Testing
@testable import Mercury

@Suite("AI Prompt Template Store")
struct AgentPromptTemplateStoreTests {
    @Test("Load built-in template from app bundle")
    func loadBuiltInTemplateFromBundle() throws {
        let store = AgentPromptTemplateStore()
        let bundle = try mercuryAppBundle()
        try store.loadBuiltInTemplates(bundle: bundle, subdirectory: "AI/Templates")

        #expect(store.loadedTemplateIDs.contains("summary.default"))
        #expect(store.loadedTemplateIDs.contains("translation.default"))
    }

    @Test("Load valid summary template and render")
    func loadAndRenderSummaryTemplate() throws {
        let store = AgentPromptTemplateStore()
        try store.loadTemplates(from: templateDirectoryInRepository())

        let template = try store.template(id: "summary.default")
        #expect(template.version == "v1")
        #expect(template.taskType == .summary)
        #expect(template.requiredPlaceholders.contains("targetLanguageDisplayName"))
        #expect(template.requiredPlaceholders.contains("shortWordMin"))
        #expect(template.optionalPlaceholders.isEmpty)

        let parameters = summaryRenderParameters()
        let rendered = try template.render(parameters: parameters)

        #expect(rendered.contains("English (en)"))
        #expect(rendered.contains("medium"))
        #expect(rendered.contains("Mercury is a local-first RSS reader."))
        #expect(rendered.contains("{{sourceText}}") == false)

        let renderedSystem = try template.renderSystem(parameters: parameters)
        #expect(renderedSystem?.contains("[HardConstraints]") == true)
        #expect(renderedSystem?.contains("80-140") == true)
        #expect(renderedSystem?.contains("TL;DR") == false)
    }

    @Test("Load valid translation template and render")
    func loadAndRenderTranslationTemplate() throws {
        let store = AgentPromptTemplateStore()
        try store.loadTemplates(from: templateDirectoryInRepository())

        let template = try store.template(id: "translation.default")
        #expect(template.version == "v1")
        #expect(template.taskType == .translation)
        #expect(template.requiredPlaceholders.contains("targetLanguageDisplayName"))
        #expect(template.requiredPlaceholders.contains("sourceSegmentsJSON"))

        let rendered = try template.render(
            parameters: [
                "targetLanguageDisplayName": "English (en)",
                "sourceSegmentsJSON": #"[{"sourceSegmentId":"seg_0_abc","sourceText":"hello"}]"#
            ]
        )

        #expect(rendered.contains("English (en)"))
        #expect(rendered.contains("seg_0_abc"))
        #expect(rendered.contains("{{sourceSegmentsJSON}}") == false)
    }

    @Test("Reject malformed template with actionable error")
    func rejectMalformedTemplate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidTemplate = """
        id: summary.invalid
        version: v1
        taskType: summary
        requiredPlaceholders:
          - targetLanguage
          - sourceText
        template: |
          Summarize this article in {{targetLanguage}}.
        """
        let fileURL = directory.appendingPathComponent("summary.invalid.yaml")
        try invalidTemplate.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AgentPromptTemplateStore()
        do {
            try store.loadTemplates(from: directory)
            Issue.record("Expected malformed template validation failure, but loading succeeded.")
        } catch let error as AgentPromptTemplateError {
            guard case let .invalidTemplateFile(name, reason) = error else {
                Issue.record("Unexpected error kind: \(error.localizedDescription)")
                return
            }
            #expect(name == "summary.invalid.yaml")
            #expect(reason.contains("Required placeholder(s) not found"))
            #expect(reason.contains("sourceText"))
        }
    }

    private func templateDirectoryInRepository() throws -> URL {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let templateDirectory = testsDirectory
            .appendingPathComponent("../Mercury/Resources/AI/Templates")
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: templateDirectory.path) else {
            throw TestError.templateDirectoryNotFound(templateDirectory.path)
        }
        return templateDirectory
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-template-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func summaryRenderParameters() -> [String: String] {
        [
            "targetLanguage": "en",
            "targetLanguageDisplayName": "English (en)",
            "detailLevel": "medium",
            "sourceText": "Mercury is a local-first RSS reader."
        ]
    }

    private func mercuryAppBundle() throws -> Bundle {
        if let bundle = Bundle.allBundles.first(where: { $0.bundleIdentifier == "net.paradigmx.Mercury" }) {
            return bundle
        }
        if let bundle = Bundle.allBundles.first(where: { $0.bundleURL.lastPathComponent == "Mercury.app" }) {
            return bundle
        }
        throw TestError.appBundleNotFound
    }
}

private enum TestError: Error {
    case templateDirectoryNotFound(String)
    case appBundleNotFound
}
