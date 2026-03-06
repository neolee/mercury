import AppKit
import Foundation

// MARK: - Config

/// Per-agent configuration for the shared prompt customization logic.
struct AgentPromptCustomizationConfig {
    /// File name written to the user's Application Support sandbox (e.g. "summary.yaml").
    let customTemplateFileName: String
    /// Base name of the built-in template resource (e.g. "summary.default").
    let builtInTemplateName: String
    /// Template ID used to look up the parsed template in AgentPromptTemplateStore.
    let templateID: String
    /// Title for the debug issue logged when the custom template is invalid.
    let invalidTemplateDebugTitle: String
    /// Localization key for the agent name inserted into the shared invalid-template fallback message.
    let invalidTemplateFallbackAgentNameKey: String

    static let builtInTemplateExtension = "yaml"
    static let templatesSubdirectory = "Agent/Prompts"

    // MARK: Named configs

    static let summary = AgentPromptCustomizationConfig(
        customTemplateFileName: "summary.yaml",
        builtInTemplateName: "summary.default",
        templateID: "summary.default",
        invalidTemplateDebugTitle: "Summary Prompt Customization Invalid",
        invalidTemplateFallbackAgentNameKey: "Summary"
    )

    static let translation = AgentPromptCustomizationConfig(
        customTemplateFileName: "translation.yaml",
        builtInTemplateName: "translation.default",
        templateID: "translation.default",
        invalidTemplateDebugTitle: "Translation Prompt Customization Invalid",
        invalidTemplateFallbackAgentNameKey: "Translation"
    )

    static let tagging = AgentPromptCustomizationConfig(
        customTemplateFileName: "tagging.yaml",
        builtInTemplateName: "tagging.default",
        templateID: "tagging.default",
        invalidTemplateDebugTitle: "Tagging Prompt Customization Invalid",
        invalidTemplateFallbackAgentNameKey: "Tagging"
    )

    @MainActor
    func invalidTemplateFallbackMessage(bundle: Bundle) -> String {
        let format = NSLocalizedString(
            "Custom %@ prompt is invalid. Using built-in prompt.",
            bundle: bundle,
            comment: ""
        )
        let agentName = NSLocalizedString(invalidTemplateFallbackAgentNameKey, bundle: bundle, comment: "")
        return String(format: format, agentName)
    }
}

// MARK: - Error

enum AgentPromptCustomizationError: LocalizedError {
    case builtInTemplateNotFound(agentName: String)

    var errorDescription: String? {
        switch self {
        case .builtInTemplateNotFound(let name):
            return "Built-in \(name) template was not found in app resources."
        }
    }
}

// MARK: - Shared Logic

enum AgentPromptCustomization {

    // MARK: Public API

    static func customTemplateFileURL(
        config: AgentPromptCustomizationConfig,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        createDirectoryIfNeeded: Bool = true
    ) throws -> URL {
        let directory = try customTemplateDirectoryURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: createDirectoryIfNeeded
        )
        return directory.appendingPathComponent(config.customTemplateFileName)
    }

    /// Copies the built-in template to the user sandbox if it is not already there,
    /// then returns the sandbox URL.
    static func ensureCustomTemplateFile(
        config: AgentPromptCustomizationConfig,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> URL {
        let destination = try customTemplateFileURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        let sourceURL = try resolvedBuiltInTemplateURL(
            config: config,
            bundle: bundle,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Loads the prompt template, preferring the user-edited sandbox copy when present.
    /// If the sandbox copy is invalid, `onInvalidCustomTemplate` is called and the built-in
    /// template is returned as a fallback (the sandbox file is preserved on disk).
    static func loadTemplate(
        config: AgentPromptCustomizationConfig,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil,
        onInvalidCustomTemplate: ((URL, Error) -> Void)? = nil
    ) throws -> AgentPromptTemplate {
        if let customURL = try existingCustomTemplateFileURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride
        ) {
            do {
                let store = AgentPromptTemplateStore()
                try store.loadTemplate(from: customURL)
                return try store.template(id: config.templateID)
            } catch {
                onInvalidCustomTemplate?(customURL, error)
                // Fall through to built-in below.
            }
        }

        if let builtInTemplateURLOverride {
            let store = AgentPromptTemplateStore()
            try store.loadTemplate(from: builtInTemplateURLOverride)
            return try store.template(id: config.templateID)
        }

        let store = AgentPromptTemplateStore()
        try store.loadBuiltInTemplates(
            bundle: bundle,
            subdirectory: AgentPromptCustomizationConfig.templatesSubdirectory
        )
        return try store.template(id: config.templateID)
    }

    // MARK: Private Helpers

    private static func existingCustomTemplateFileURL(
        config: AgentPromptCustomizationConfig,
        fileManager: FileManager,
        appSupportDirectoryOverride: URL?
    ) throws -> URL? {
        let url = try customTemplateFileURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: false
        )
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func customTemplateDirectoryURL(
        fileManager: FileManager,
        appSupportDirectoryOverride: URL?,
        createDirectoryIfNeeded: Bool
    ) throws -> URL {
        let appSupport: URL
        if let appSupportDirectoryOverride {
            appSupport = appSupportDirectoryOverride
            if createDirectoryIfNeeded {
                try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
            }
        } else {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let templatesDirectory = appSupport
            .appendingPathComponent("Mercury", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
            .appendingPathComponent("Prompts", isDirectory: true)
        if createDirectoryIfNeeded {
            try fileManager.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        }
        return templatesDirectory
    }

    private static func resolvedBuiltInTemplateURL(
        config: AgentPromptCustomizationConfig,
        bundle: Bundle,
        builtInTemplateURLOverride: URL?
    ) throws -> URL {
        if let builtInTemplateURLOverride {
            return builtInTemplateURLOverride
        }
        if let url = bundle.url(
            forResource: config.builtInTemplateName,
            withExtension: AgentPromptCustomizationConfig.builtInTemplateExtension,
            subdirectory: AgentPromptCustomizationConfig.templatesSubdirectory
        ) {
            return url
        }
        if let url = bundle.url(
            forResource: config.builtInTemplateName,
            withExtension: AgentPromptCustomizationConfig.builtInTemplateExtension,
            subdirectory: nil
        ) {
            return url
        }
        throw AgentPromptCustomizationError.builtInTemplateNotFound(agentName: config.builtInTemplateName)
    }
}

// MARK: - AppModel Integration

extension AppModel {
    /// Loads the agent prompt template for the given config. If the user's custom template
    /// is present but invalid, automatically: logs a debug issue, then calls `onNotice` with
    /// a localized reader banner message, and falls back to the built-in template.
    func loadPromptTemplate(
        config: AgentPromptCustomizationConfig,
        onNotice: @escaping (String) async -> Void
    ) async throws -> AgentPromptTemplate {
        var invalidDetail: String?
        let template = try AgentPromptCustomization.loadTemplate(
            config: config,
            onInvalidCustomTemplate: { url, error in
                invalidDetail = [
                    "path=\(url.path)",
                    "error=\(error.localizedDescription)",
                    "action=fallback_to_built_in_template"
                ].joined(separator: "\n")
            }
        )
        if let invalidDetail {
            let message = await MainActor.run {
                config.invalidTemplateFallbackMessage(bundle: LanguageManager.shared.bundle)
            }
            await MainActor.run {
                self.reportDebugIssue(
                    title: config.invalidTemplateDebugTitle,
                    detail: invalidDetail,
                    category: .task
                )
            }
            await onNotice(message)
        }
        return template
    }

    /// Ensures the custom template file exists (copying from built-in if needed),
    /// then reveals it in Finder.
    @discardableResult
    @MainActor
    func revealCustomPromptInFinder(config: AgentPromptCustomizationConfig) throws -> URL {
        let fileURL = try AgentPromptCustomization.ensureCustomTemplateFile(config: config)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return fileURL
    }
}
