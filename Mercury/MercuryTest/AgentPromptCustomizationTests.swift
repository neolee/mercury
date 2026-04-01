import Foundation
import Testing
@testable import Mercury

@Suite("Agent Prompt Customization")
struct AgentPromptCustomizationTests {
    @Test("Create custom template from built-in when missing for all agents")
    func createCustomTemplateWhenMissing() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-appsupport")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            let builtInContent = makeTemplate(
                id: agent.config.templateID,
                version: "builtin-v1",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            )
            try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

            let destination = try AgentPromptCustomization.ensureCustomTemplateFile(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(fileManager.fileExists(atPath: destination.path))
            #expect(destination.lastPathComponent == agent.config.customTemplateFileName)
            let copied = try String(contentsOf: destination, encoding: .utf8)
            #expect(copied == builtInContent)
        }
    }

    @Test("Skip copy when custom template already exists for all agents")
    func skipCopyWhenCustomTemplateExists() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-existing")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-existing-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let existingCustomURL = try AgentPromptCustomization.customTemplateFileURL(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            let existingContent = makeTemplate(
                id: agent.config.templateID,
                version: "custom-existing",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            )
            try existingContent.write(to: existingCustomURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            let builtInContent = makeTemplate(
                id: agent.config.templateID,
                version: "builtin-v2",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            )
            try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

            let resolved = try AgentPromptCustomization.ensureCustomTemplateFile(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(resolved.path == existingCustomURL.path)
            let currentContent = try String(contentsOf: resolved, encoding: .utf8)
            #expect(currentContent == existingContent)
        }
    }

    @Test("Prefer custom template when present for all agents")
    func preferCustomTemplateWhenPresent() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-prefer-custom")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-prefer-custom-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try AgentPromptCustomization.customTemplateFileURL(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try makeTemplate(
                id: agent.config.templateID,
                version: "v3",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.config.templateID,
                version: "v3",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let template = try AgentPromptCustomization.loadTemplate(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(template.id == agent.config.templateID)
            #expect(template.version == "v3")
            #expect(template.taskType == agent.taskType)
        }
    }

    @Test("Fallback to built-in template when custom template version mismatches for all agents")
    func fallbackToBuiltInTemplateWhenCustomVersionMismatches() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-version-mismatch")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-version-mismatch-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try AgentPromptCustomization.customTemplateFileURL(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try makeTemplate(
                id: agent.config.templateID,
                version: "v2",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.config.templateID,
                version: "v3",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            var rejectedPath: String?
            var rejectedReason: TemplateCustomizationFallbackReason?
            let template = try AgentPromptCustomization.loadTemplate(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL,
                onRejectedCustomTemplate: { rejected in
                    rejectedPath = rejected.fileURL.path
                    rejectedReason = rejected.reason
                }
            )

            #expect(template.version == "v3")
            #expect(rejectedPath == customURL.path)
            #expect(
                rejectedReason
                    == .versionMismatch(customVersion: "v2", builtInVersion: "v3")
            )
            #expect(fileManager.fileExists(atPath: customURL.path))
        }
    }

    @Test("Custom template loading ignores sibling yaml files for all agents")
    func customTemplateLoadingIgnoresSiblingYAML() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-sibling")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-sibling-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try AgentPromptCustomization.customTemplateFileURL(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try makeTemplate(
                id: agent.config.templateID,
                version: "v11",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: customURL, atomically: true, encoding: .utf8)

            let siblingURL = customURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(agent.name).backup.yaml")
            try makeTemplate(
                id: "\(agent.config.templateID).backup",
                version: "backup-v0",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: siblingURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.config.templateID,
                version: "v11",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let template = try AgentPromptCustomization.loadTemplate(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(template.version == "v11")
        }
    }

    @Test("Fallback to built-in template when custom is absent for all agents")
    func fallbackToBuiltInTemplateWhenCustomMissing() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-fallback-appsupport")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-fallback-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.config.templateID,
                version: "builtin-v7",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let template = try AgentPromptCustomization.loadTemplate(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(template.id == agent.config.templateID)
            #expect(template.version == "builtin-v7")
            #expect(template.taskType == agent.taskType)
        }
    }

    @Test("Fallback to built-in template when custom template is invalid for all agents")
    func fallbackToBuiltInTemplateWhenCustomInvalid() throws {
        for agent in agentCases {
            let fileManager = FileManager.default
            let appSupport = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-invalid-custom")
            let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-\(agent.name)-prompts-invalid-builtin")
            defer {
                try? fileManager.removeItem(at: appSupport)
                try? fileManager.removeItem(at: builtInDirectory)
            }

            let customURL = try AgentPromptCustomization.customTemplateFileURL(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try "not: [valid: yaml".write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.config.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.config.templateID,
                version: "builtin-v8",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            var reportedPath: String?
            let template = try AgentPromptCustomization.loadTemplate(
                config: agent.config,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL,
                onRejectedCustomTemplate: { rejected in
                    reportedPath = rejected.fileURL.path
                }
            )

            #expect(template.version == "builtin-v8")
            #expect(reportedPath == customURL.path)
            #expect(fileManager.fileExists(atPath: customURL.path))
        }
    }

    private var agentCases: [PromptCustomizationCase] {
        [
            PromptCustomizationCase(
                name: "summary",
                config: .summary,
                taskType: .summary,
                bodyLabel: "Summarize"
            ),
            PromptCustomizationCase(
                name: "translation",
                config: .translation,
                taskType: .translation,
                bodyLabel: "Translate"
            ),
            PromptCustomizationCase(
                name: "tagging",
                config: .tagging,
                taskType: .tagging,
                bodyLabel: "Tag"
            )
        ]
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTemplate(
        id: String,
        version: String,
        taskType: AgentTaskType,
        bodyLabel: String
    ) -> String {
        """
        id: \(id)
        version: \(version)
        taskType: \(taskType.rawValue)
        template: |
          \(bodyLabel) article:
          {{sourceText}}
        """
    }
}

private struct PromptCustomizationCase {
    let name: String
    let config: AgentPromptCustomizationConfig
    let taskType: AgentTaskType
    let bodyLabel: String
}
