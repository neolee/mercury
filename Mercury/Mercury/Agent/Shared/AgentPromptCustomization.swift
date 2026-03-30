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

    var customization: TemplateCustomizationResourceConfig {
        TemplateCustomizationResourceConfig(
            customTemplateFileName: customTemplateFileName,
            builtInTemplateName: builtInTemplateName,
            builtInTemplateExtension: Self.builtInTemplateExtension,
            builtInTemplatesSubdirectory: Self.templatesSubdirectory,
            applicationSupportPathComponents: ["Mercury", "Agent", "Prompts"]
        )
    }

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
        try TemplateCustomization.customTemplateFileURL(
            config: config.customization,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: createDirectoryIfNeeded
        )
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
        try TemplateCustomization.ensureCustomTemplateFile(
            config: config.customization,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
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
        let result = try TemplateCustomization.loadTemplate(
            config: config.customization,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride,
            loadFromFile: { fileURL in
                let store = AgentPromptTemplateStore()
                try store.loadTemplate(from: fileURL)
                return try store.template(id: config.templateID)
            }
        )

        if let invalidCustomTemplate = result.invalidCustomTemplate {
            let invalidError = NSError(
                domain: "Mercury.AgentPromptCustomization",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: invalidCustomTemplate.errorDescription]
            )
            onInvalidCustomTemplate?(invalidCustomTemplate.fileURL, invalidError)
        }

        return result.template
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
        let result = try TemplateCustomization.loadTemplate(
            config: config.customization,
            loadFromFile: { fileURL in
                let store = AgentPromptTemplateStore()
                try store.loadTemplate(from: fileURL)
                return try store.template(id: config.templateID)
            }
        )
        if let invalidCustomTemplate = result.invalidCustomTemplate {
            let message = await MainActor.run {
                config.invalidTemplateFallbackMessage(bundle: LanguageManager.shared.bundle)
            }
            await MainActor.run {
                self.reportDebugIssue(
                    title: config.invalidTemplateDebugTitle,
                    detail: TemplateCustomization.invalidCustomTemplateDebugDetail(invalidCustomTemplate),
                    category: .task
                )
            }
            await onNotice(message)
        }
        return result.template
    }

    /// Ensures the custom template file exists (copying from built-in if needed),
    /// then reveals it in Finder.
    @discardableResult
    @MainActor
    func revealCustomPromptInFinder(config: AgentPromptCustomizationConfig) throws -> URL {
        try TemplateCustomization.ensureCustomTemplateFileAndRevealInFinder(config: config.customization)
    }
}
