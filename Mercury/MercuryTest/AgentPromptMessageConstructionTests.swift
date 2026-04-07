import Foundation
import Testing
@testable import Mercury

@Suite("Agent Prompt Message Construction")
struct AgentPromptMessageConstructionTests {
    @Test("Summary prompt messages are built from template render output")
    func summaryPromptMessagesFromTemplate() throws {
        let template = try loadBuiltInTemplate(id: "summary.default")
        let messages = try buildSummaryPromptMessages(
            template: template,
            renderParameters: [
                "targetLanguage": "en",
                "targetLanguageDisplayName": "English (en)",
                "detailLevel": "medium",
                "sourceText": "Mercury is a local-first RSS reader."
            ]
        )

        #expect(messages.messages.count == 2)
        #expect(messages.messages[0].role == "system")
        #expect(messages.messages[0].content.contains("senior editorial summarization assistant"))
        #expect(messages.messages[1].role == "user")
        #expect(messages.messages[1].content.contains("Mercury is a local-first RSS reader."))
    }

    @Test("Summary prompt messages use current executor fallback when system template is absent")
    func summaryPromptMessagesFallbackWhenSystemTemplateAbsent() throws {
        let template = try loadInlineTemplate(
            id: "summary.no-system",
            version: "v1",
            taskType: .summary,
            body: "Summarize:\n{{sourceText}}"
        )
        let messages = try buildSummaryPromptMessages(
            template: template,
            renderParameters: [
                "sourceText": "Mercury"
            ]
        )

        #expect(messages.systemPrompt == "You are a concise agent.")
        #expect(messages.userPrompt == "Summarize:\nMercury")
    }

    @Test("Translation prompt messages expose current previous-context injection")
    func translationPromptMessagesWithPreviousContext() throws {
        let template = try loadBuiltInTemplate(id: "translation.default")
        let messages = try buildTranslationPromptMessages(
            template: template,
            targetLanguageDisplayName: "Chinese (zh)",
            sourceText: "Current paragraph.",
            previousSourceText: "Previous paragraph."
        )

        #expect(messages.messages.count == 2)
        #expect(messages.systemPrompt.contains("professional translator"))
        #expect(messages.userPrompt.contains("Context (preceding paragraph, do not translate):"))
        #expect(messages.userPrompt.contains("Previous paragraph."))
        #expect(messages.userPrompt.contains("Current paragraph."))
    }

    @Test("Translation prompt messages omit previous-context block when absent")
    func translationPromptMessagesWithoutPreviousContext() throws {
        let template = try loadBuiltInTemplate(id: "translation.default")
        let messages = try buildTranslationPromptMessages(
            template: template,
            targetLanguageDisplayName: "Chinese (zh)",
            sourceText: "Current paragraph.",
            previousSourceText: nil
        )

        #expect(messages.userPrompt.contains("Context (preceding paragraph, do not translate):") == false)
        #expect(messages.userPrompt.contains("Current paragraph."))
    }

    @Test("Tagging prompt messages are built directly from template render output")
    func taggingPromptMessagesFromTemplate() throws {
        let template = try loadBuiltInTemplate(id: "tagging.default")
        let messages = try buildTaggingPromptMessages(
            template: template,
            renderParameters: [
                "existingTagsJson": "[\"Rust\"]",
                "maxTagCount": "5",
                "maxNewTagCount": "3",
                "bodyKind": "article excerpt",
                "title": "Understanding Rust",
                "body": "Ownership and borrowing explained."
            ]
        )

        #expect(messages.messages.count == 2)
        #expect(messages.systemPrompt.contains("precise topic tagging assistant"))
        #expect(messages.systemPrompt.contains("article excerpt"))
        #expect(messages.userPrompt.contains("Understanding Rust"))
        #expect(messages.userPrompt.contains("Ownership and borrowing explained."))
    }

    private func loadBuiltInTemplate(id: String) throws -> AgentPromptTemplate {
        let store = AgentPromptTemplateStore()
        try store.loadTemplates(from: templateDirectoryInRepository())
        return try store.template(id: id)
    }

    private func loadInlineTemplate(
        id: String,
        version: String,
        taskType: AgentTaskType,
        body: String
    ) throws -> AgentPromptTemplate {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = """
        id: \(id)
        version: \(version)
        taskType: \(taskType.rawValue)
        requiredPlaceholders:
          - sourceText
        template: |
          \(body.replacingOccurrences(of: "\n", with: "\n  "))
        """
        let fileURL = directory.appendingPathComponent("\(id).yaml")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AgentPromptTemplateStore()
        try store.loadTemplates(from: directory)
        return try store.template(id: id)
    }

    private func templateDirectoryInRepository() throws -> URL {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let templateDirectory = testsDirectory
            .appendingPathComponent("../Mercury/Resources/Agent/Prompts")
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: templateDirectory.path) else {
            throw TestError.templateDirectoryNotFound(templateDirectory.path)
        }
        return templateDirectory
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mercury-agent-prompt-message-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum TestError: Error {
    case templateDirectoryNotFound(String)
}