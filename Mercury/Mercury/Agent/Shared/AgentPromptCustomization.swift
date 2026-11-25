import Foundation

// MARK: - Descriptor

/// Stable identifier for a model-family-oriented prompt variant.
nonisolated enum AgentPromptVariant: String, Sendable, Hashable, CaseIterable {
    case `default` = "default"
    case hyMT = "hy-mt"
}

/// Immutable descriptor for one built-in prompt template and its custom override.
nonisolated struct AgentPromptTemplateDescriptor {
    /// Agent task type this template belongs to.
    let agent: AgentTaskType
    /// Prompt variant within the agent task type.
    let variant: AgentPromptVariant
    /// Title for the debug issue logged when the custom template is invalid.
    let invalidTemplateDebugTitle: String
    /// Title for the debug issue logged when the custom template version mismatches the built-in version.
    let versionMismatchDebugTitle: String
    /// Localization key for the agent name inserted into the shared invalid-template fallback message.
    let invalidTemplateFallbackAgentNameKey: String

    static let builtInTemplateExtension = "yaml"
    static let templatesSubdirectory = "Agent/Prompts"

    private init(
        agent: AgentTaskType,
        variant: AgentPromptVariant,
        invalidTemplateDebugTitle: String,
        versionMismatchDebugTitle: String,
        invalidTemplateFallbackAgentNameKey: String
    ) {
        self.agent = agent
        self.variant = variant
        self.invalidTemplateDebugTitle = invalidTemplateDebugTitle
        self.versionMismatchDebugTitle = versionMismatchDebugTitle
        self.invalidTemplateFallbackAgentNameKey = invalidTemplateFallbackAgentNameKey
    }

    /// Canonical template ID and built-in resource base name.
    var templateID: String {
        "\(agent.rawValue).\(variant.rawValue)"
    }

    /// Base name of the built-in template resource.
    var builtInTemplateName: String {
        templateID
    }

    /// Canonical custom template file name in the user's Application Support sandbox.
    var customTemplateFileName: String {
        "\(templateID).yaml"
    }

    var customization: TemplateCustomizationResourceConfig {
        TemplateCustomizationResourceConfig(
            customTemplateFileName: customTemplateFileName,
            builtInTemplateName: builtInTemplateName,
            builtInTemplateExtension: Self.builtInTemplateExtension,
            builtInTemplatesSubdirectory: Self.templatesSubdirectory,
            applicationSupportPathComponents: ["Mercury", "Agent", "Prompts"]
        )
    }

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

    @MainActor
    func versionMismatchFallbackMessage(
        customVersion: String,
        builtInVersion: String,
        bundle: Bundle
    ) -> String {
        let format = NSLocalizedString(
            "Custom %@ prompt template version (%@) does not match the built-in version (%@). Using built-in prompt.",
            bundle: bundle,
            comment: ""
        )
        let agentName = NSLocalizedString(invalidTemplateFallbackAgentNameKey, bundle: bundle, comment: "")
        return String(format: format, agentName, customVersion, builtInVersion)
    }

    @MainActor
    func fallbackMessage(for reason: TemplateCustomizationFallbackReason, bundle: Bundle) -> String {
        switch reason {
        case .invalidCustomTemplate:
            return invalidTemplateFallbackMessage(bundle: bundle)
        case .versionMismatch(let customVersion, let builtInVersion):
            return versionMismatchFallbackMessage(
                customVersion: customVersion,
                builtInVersion: builtInVersion,
                bundle: bundle
            )
        }
    }

    func debugTitle(for reason: TemplateCustomizationFallbackReason) -> String {
        switch reason {
        case .invalidCustomTemplate:
            return invalidTemplateDebugTitle
        case .versionMismatch:
            return versionMismatchDebugTitle
        }
    }

    // MARK: Catalog

    static let summaryDefault = AgentPromptTemplateDescriptor(
        agent: .summary,
        variant: .default,
        invalidTemplateDebugTitle: "Summary Prompt Customization Invalid",
        versionMismatchDebugTitle: "Summary Prompt Customization Version Mismatch",
        invalidTemplateFallbackAgentNameKey: "Summary"
    )

    static let translationDefault = AgentPromptTemplateDescriptor(
        agent: .translation,
        variant: .default,
        invalidTemplateDebugTitle: "Translation (Standard) Prompt Customization Invalid",
        versionMismatchDebugTitle: "Translation (Standard) Prompt Customization Version Mismatch",
        invalidTemplateFallbackAgentNameKey: "Translation"
    )

    static let translationHYMT = AgentPromptTemplateDescriptor(
        agent: .translation,
        variant: .hyMT,
        invalidTemplateDebugTitle: "Translation (HY-MT Optimized) Prompt Customization Invalid",
        versionMismatchDebugTitle: "Translation (HY-MT Optimized) Prompt Customization Version Mismatch",
        invalidTemplateFallbackAgentNameKey: "HY-MT Optimized"
    )

    static let taggingDefault = AgentPromptTemplateDescriptor(
        agent: .tagging,
        variant: .default,
        invalidTemplateDebugTitle: "Tagging Prompt Customization Invalid",
        versionMismatchDebugTitle: "Tagging Prompt Customization Version Mismatch",
        invalidTemplateFallbackAgentNameKey: "Tagging"
    )

    static let all: [AgentPromptTemplateDescriptor] = [
        .summaryDefault,
        .translationDefault,
        .translationHYMT,
        .taggingDefault
    ]

    static let translationVariants: [AgentPromptVariant] = [
        .default,
        .hyMT
    ]

    static func translation(for variant: AgentPromptVariant) -> AgentPromptTemplateDescriptor {
        switch variant {
        case .default:
            return .translationDefault
        case .hyMT:
            return .translationHYMT
        }
    }
}

// MARK: - Error

nonisolated enum AgentPromptCustomizationError: LocalizedError {
    case builtInTemplateNotFound(agentName: String)

    var errorDescription: String? {
        switch self {
        case .builtInTemplateNotFound(let name):
            return "Built-in \(name) template was not found in app resources."
        }
    }
}

// MARK: - Shared Logic

nonisolated enum AgentPromptCustomization {

    // MARK: Public API

    static func customTemplateFileURL(
        descriptor: AgentPromptTemplateDescriptor,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        createDirectoryIfNeeded: Bool = true
    ) throws -> URL {
        try TemplateCustomization.customTemplateFileURL(
            config: descriptor.customization,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: createDirectoryIfNeeded
        )
    }

    /// Copies the built-in template to the user sandbox if it is not already there,
    /// then returns the sandbox URL.
    static func ensureCustomTemplateFile(
        descriptor: AgentPromptTemplateDescriptor,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> URL {
        try TemplateCustomization.ensureCustomTemplateFile(
            config: descriptor.customization,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
    }

    /// Loads the prompt template, preferring the user-edited sandbox copy when present.
    /// If the sandbox copy is structurally invalid or its version mismatches the built-in
    /// template, the result contains the rejection reason and the built-in template as a
    /// fallback (the sandbox file is preserved on disk).
    static func loadTemplate(
        descriptor: AgentPromptTemplateDescriptor,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> TemplateCustomizationLoadResult<AgentPromptTemplate> {
        try TemplateCustomization.loadTemplate(
            config: descriptor.customization,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride,
            templateVersion: \.version,
            loadFromFile: { fileURL in
                let store = AgentPromptTemplateStore()
                try store.loadTemplate(from: fileURL)
                return try store.template(id: descriptor.templateID)
            }
        )
    }
}
