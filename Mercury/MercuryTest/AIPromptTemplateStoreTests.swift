import Foundation
import Testing
@testable import Mercury

@Suite("AI Prompt Template Store")
struct AIPromptTemplateStoreTests {
    @Test("Load built-in template from app bundle")
    func loadBuiltInTemplateFromBundle() throws {
        let store = AIPromptTemplateStore()
        let bundle = try mercuryAppBundle()
        try store.loadBuiltInTemplates(bundle: bundle, subdirectory: "AI/Templates")

        #expect(store.loadedTemplateIDs.contains("summary.default"))
    }

    @Test("Load valid summary template and render")
    func loadAndRenderSummaryTemplate() throws {
        let store = AIPromptTemplateStore()
        try store.loadTemplates(from: templateDirectoryInRepository())

        let template = try store.template(id: "summary.default")
        #expect(template.version == "v1")
        #expect(template.taskType == .summary)

        let rendered = try template.render(parameters: [
            "targetLanguage": "en",
            "detailLevel": "medium",
            "sourceText": "Mercury is a local-first RSS reader."
        ])

        #expect(rendered.contains("in en"))
        #expect(rendered.contains("medium"))
        #expect(rendered.contains("Mercury is a local-first RSS reader."))
        #expect(rendered.contains("{{sourceText}}") == false)
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

        let store = AIPromptTemplateStore()
        do {
            try store.loadTemplates(from: directory)
            Issue.record("Expected malformed template validation failure, but loading succeeded.")
        } catch let error as AIPromptTemplateError {
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
