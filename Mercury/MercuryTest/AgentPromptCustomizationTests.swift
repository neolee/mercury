import Foundation
import Testing
@testable import Mercury

@Suite("Agent Prompt Customization")
@MainActor
struct AgentPromptCustomizationTests {
    @Test("Descriptor identity derives canonical template IDs and file names")
    func descriptorIdentityDerivesCanonicalNames() {
        #expect(AgentPromptVariant.default.rawValue == "default")
        #expect(AgentPromptVariant.hyMT.rawValue == "hy-mt")
        #expect(AgentPromptTemplateDescriptor.all.count == 4)
        #expect(
            Set(AgentPromptTemplateDescriptor.all.map(\.templateID))
                == Set([
                    "summary.default",
                    "translation.default",
                    "translation.hy-mt",
                    "tagging.default"
                ])
        )
        #expect(AgentPromptTemplateDescriptor.summaryDefault.agent.rawValue == "summary")
        #expect(AgentPromptTemplateDescriptor.translationDefault.agent.rawValue == "translation")
        #expect(AgentPromptTemplateDescriptor.translationHYMT.agent.rawValue == "translation")
        #expect(AgentPromptTemplateDescriptor.taggingDefault.agent.rawValue == "tagging")

        for descriptor in AgentPromptTemplateDescriptor.all {
            #expect(
                descriptor.templateID
                    == "\(descriptor.agent.rawValue).\(descriptor.variant.rawValue)"
            )
            #expect(descriptor.builtInTemplateName == descriptor.templateID)
            #expect(descriptor.customTemplateFileName == "\(descriptor.templateID).yaml")
        }

        #expect(
            AgentPromptTemplateDescriptor.translation(for: .default).templateID
                == "translation.default"
        )
        #expect(
            AgentPromptTemplateDescriptor.translation(for: .hyMT).templateID
                == "translation.hy-mt"
        )
    }

    @Test("Translation descriptors expose variant-specific debug titles")
    func translationDescriptorsExposeVariantSpecificDebugTitles() {
        #expect(
            AgentPromptTemplateDescriptor.translationDefault.debugTitle(for: .invalidCustomTemplate)
                == "Translation (Standard) Prompt Customization Invalid"
        )
        #expect(
            AgentPromptTemplateDescriptor.translationHYMT.debugTitle(for: .invalidCustomTemplate)
                == "Translation (HY-MT Optimized) Prompt Customization Invalid"
        )
        #expect(
            AgentPromptTemplateDescriptor.translationDefault.debugTitle(
                for: .versionMismatch(customVersion: "v2", builtInVersion: "v3")
            ) == "Translation (Standard) Prompt Customization Version Mismatch"
        )
        #expect(
            AgentPromptTemplateDescriptor.translationHYMT.debugTitle(
                for: .versionMismatch(customVersion: "v2", builtInVersion: "v3")
            ) == "Translation (HY-MT Optimized) Prompt Customization Version Mismatch"
        )
    }

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

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            let builtInContent = makeTemplate(
                id: agent.descriptor.templateID,
                version: "builtin-v1",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            )
            try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

            let destination = try AgentPromptCustomization.ensureCustomTemplateFile(
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(fileManager.fileExists(atPath: destination.path))
            #expect(destination.lastPathComponent == agent.descriptor.customTemplateFileName)
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
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            let existingContent = makeTemplate(
                id: agent.descriptor.templateID,
                version: "custom-existing",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            )
            try existingContent.write(to: existingCustomURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            let builtInContent = makeTemplate(
                id: agent.descriptor.templateID,
                version: "builtin-v2",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            )
            try builtInContent.write(to: builtInURL, atomically: true, encoding: .utf8)

            let resolved = try AgentPromptCustomization.ensureCustomTemplateFile(
                descriptor: agent.descriptor,
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
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "v3",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "v3",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let result = try AgentPromptCustomization.loadTemplate(
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )
            let template = result.template

            #expect(template.id == agent.descriptor.templateID)
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
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "v2",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "v3",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let result = try AgentPromptCustomization.loadTemplate(
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )
            let template = result.template

            #expect(template.version == "v3")
            #expect(result.rejectedCustomTemplate?.fileURL.path == customURL.path)
            #expect(
                result.rejectedCustomTemplate?.reason
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
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "v11",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: customURL, atomically: true, encoding: .utf8)

            let siblingURL = customURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(agent.name).backup.yaml")
            try makeTemplate(
                id: "\(agent.descriptor.templateID).backup",
                version: "backup-v0",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: siblingURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "v11",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let result = try AgentPromptCustomization.loadTemplate(
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(result.template.version == "v11")
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

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "builtin-v7",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let result = try AgentPromptCustomization.loadTemplate(
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(result.template.id == agent.descriptor.templateID)
            #expect(result.template.version == "builtin-v7")
            #expect(result.template.taskType == agent.taskType)
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
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                createDirectoryIfNeeded: true
            )
            try "not: [valid: yaml".write(to: customURL, atomically: true, encoding: .utf8)

            let builtInURL = builtInDirectory.appendingPathComponent("\(agent.descriptor.builtInTemplateName).yaml")
            try makeTemplate(
                id: agent.descriptor.templateID,
                version: "builtin-v8",
                taskType: agent.taskType,
                bodyLabel: agent.bodyLabel
            ).write(to: builtInURL, atomically: true, encoding: .utf8)

            let result = try AgentPromptCustomization.loadTemplate(
                descriptor: agent.descriptor,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )

            #expect(result.template.version == "builtin-v8")
            #expect(result.rejectedCustomTemplate?.fileURL.path == customURL.path)
            #expect(fileManager.fileExists(atPath: customURL.path))
        }
    }

    @Test("Summary invalid built-in template fails explicitly")
    func summaryInvalidBuiltInTemplateFailsExplicitly() throws {
        let fileManager = FileManager.default
        let appSupport = try makeTemporaryDirectory(prefix: "mercury-summary-prompts-invalid-builtin-appsupport")
        let builtInDirectory = try makeTemporaryDirectory(prefix: "mercury-summary-prompts-invalid-builtin")
        defer {
            try? fileManager.removeItem(at: appSupport)
            try? fileManager.removeItem(at: builtInDirectory)
        }

        let builtInURL = builtInDirectory.appendingPathComponent("summary.default.yaml")
        let invalidBuiltIn = """
        id: summary.default
        version: v999
        taskType: summary
        requiredPlaceholders:
          - sourceText
        template: |
          Missing {{targetLanguageDisplayName}}
        """
        try invalidBuiltIn.write(to: builtInURL, atomically: true, encoding: .utf8)

        do {
            _ = try AgentPromptCustomization.loadTemplate(
                descriptor: .summaryDefault,
                fileManager: fileManager,
                appSupportDirectoryOverride: appSupport,
                builtInTemplateURLOverride: builtInURL
            )
            Issue.record("Expected invalid built-in Summary template to fail explicitly, but loading succeeded.")
        } catch let error as AgentPromptTemplateError {
            guard case let .invalidTemplateFile(name, reason) = error else {
                Issue.record("Unexpected error kind: \(error.localizedDescription)")
                return
            }
            #expect(name == "summary.default.yaml")
            #expect(reason.contains("sourceText"))
        }
    }

    private var agentCases: [PromptCustomizationCase] {
        [
            PromptCustomizationCase(
                name: "summary",
                descriptor: .summaryDefault,
                taskType: .summary,
                bodyLabel: "Summarize"
            ),
            PromptCustomizationCase(
                name: "translation-standard",
                descriptor: .translationDefault,
                taskType: .translation,
                bodyLabel: "Translate"
            ),
            PromptCustomizationCase(
                name: "translation-hy-mt",
                descriptor: .translationHYMT,
                taskType: .translation,
                bodyLabel: "Translate HY"
            ),
            PromptCustomizationCase(
                name: "tagging",
                descriptor: .taggingDefault,
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
    let descriptor: AgentPromptTemplateDescriptor
    let taskType: AgentTaskType
    let bodyLabel: String
}
