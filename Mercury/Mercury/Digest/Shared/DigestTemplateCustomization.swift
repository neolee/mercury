import Foundation

struct DigestTemplateCustomizationConfig {
    let customization: TemplateCustomizationResourceConfig
    let templateID: String
    let invalidTemplateDebugTitle: String
    let versionMismatchDebugTitle: String
    let invalidTemplateDisplayNameKey: String

    static let shareDigest = DigestTemplateCustomizationConfig(
        customization: TemplateCustomizationResourceConfig(
            customTemplateFileName: "single-text.yaml",
            builtInTemplateName: "single-text",
            builtInTemplateExtension: "yaml",
            builtInTemplatesSubdirectory: DigestTemplateStore.builtInSubdirectory,
            applicationSupportPathComponents: ["Mercury", "Digest", "Templates"]
        ),
        templateID: DigestPolicy.singleTextTemplateID,
        invalidTemplateDebugTitle: "Share Digest Template Customization Invalid",
        versionMismatchDebugTitle: "Share Digest Template Customization Version Mismatch",
        invalidTemplateDisplayNameKey: "Share Digest"
    )

    static let exportDigest = DigestTemplateCustomizationConfig(
        customization: TemplateCustomizationResourceConfig(
            customTemplateFileName: "single-markdown.yaml",
            builtInTemplateName: "single-markdown",
            builtInTemplateExtension: "yaml",
            builtInTemplatesSubdirectory: DigestTemplateStore.builtInSubdirectory,
            applicationSupportPathComponents: ["Mercury", "Digest", "Templates"]
        ),
        templateID: DigestPolicy.singleMarkdownTemplateID,
        invalidTemplateDebugTitle: "Export Digest Template Customization Invalid",
        versionMismatchDebugTitle: "Export Digest Template Customization Version Mismatch",
        invalidTemplateDisplayNameKey: "Export Digest"
    )

    static let exportMultipleDigest = DigestTemplateCustomizationConfig(
        customization: TemplateCustomizationResourceConfig(
            customTemplateFileName: "multiple-markdown.yaml",
            builtInTemplateName: "multiple-markdown",
            builtInTemplateExtension: "yaml",
            builtInTemplatesSubdirectory: DigestTemplateStore.builtInSubdirectory,
            applicationSupportPathComponents: ["Mercury", "Digest", "Templates"]
        ),
        templateID: DigestPolicy.multipleMarkdownTemplateID,
        invalidTemplateDebugTitle: "Export Multiple Digest Template Customization Invalid",
        versionMismatchDebugTitle: "Export Multiple Digest Template Customization Version Mismatch",
        invalidTemplateDisplayNameKey: "Export Multiple Digest"
    )

    @MainActor
    func invalidTemplateFallbackMessage(bundle: Bundle) -> String {
        let format = NSLocalizedString(
            "Custom %@ template is invalid. Using built-in template.",
            bundle: bundle,
            comment: ""
        )
        let displayName = NSLocalizedString(invalidTemplateDisplayNameKey, bundle: bundle, comment: "")
        return String(format: format, displayName)
    }

    @MainActor
    func versionMismatchFallbackMessage(
        customVersion: String,
        builtInVersion: String,
        bundle: Bundle
    ) -> String {
        let format = NSLocalizedString(
            "Custom %@ template version (%@) does not match the built-in version (%@). Using built-in template.",
            bundle: bundle,
            comment: ""
        )
        let displayName = NSLocalizedString(invalidTemplateDisplayNameKey, bundle: bundle, comment: "")
        return String(format: format, displayName, customVersion, builtInVersion)
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
}

enum DigestTemplateCustomization {
    static func customTemplateFileURL(
        config: DigestTemplateCustomizationConfig,
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

    static func ensureCustomTemplateFile(
        config: DigestTemplateCustomizationConfig,
        bundle: Bundle = DigestResourceBundleLocator.bundle(),
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

    static func loadTemplate(
        config: DigestTemplateCustomizationConfig,
        bundle: Bundle = DigestResourceBundleLocator.bundle(),
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil,
        onRejectedCustomTemplate: ((TemplateCustomizationRejectedCustomTemplate) -> Void)? = nil
    ) throws -> DigestTemplate {
        let result = try TemplateCustomization.loadTemplate(
            config: config.customization,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride,
            templateVersion: \.version,
            loadFromFile: { fileURL in
                let store = DigestTemplateStore()
                try store.loadTemplate(from: fileURL)
                return try store.template(id: config.templateID)
            }
        )

        if let rejectedCustomTemplate = result.rejectedCustomTemplate {
            onRejectedCustomTemplate?(rejectedCustomTemplate)
        }

        return result.template
    }
}

extension AppModel {
    func loadDigestTemplate(
        config: DigestTemplateCustomizationConfig,
        onNotice: @escaping (String) async -> Void
    ) async throws -> DigestTemplate {
        let result = try TemplateCustomization.loadTemplate(
            config: config.customization,
            bundle: DigestResourceBundleLocator.bundle(),
            templateVersion: \.version,
            loadFromFile: { fileURL in
                let store = DigestTemplateStore()
                try store.loadTemplate(from: fileURL)
                return try store.template(id: config.templateID)
            }
        )

        if let rejectedCustomTemplate = result.rejectedCustomTemplate {
            await MainActor.run {
                self.reportDebugIssue(
                    title: config.debugTitle(for: rejectedCustomTemplate.reason),
                    detail: TemplateCustomization.rejectedCustomTemplateDebugDetail(rejectedCustomTemplate),
                    category: .task
                )
            }
            let message = await MainActor.run {
                config.fallbackMessage(
                    for: rejectedCustomTemplate.reason,
                    bundle: LanguageManager.shared.bundle
                )
            }
            await onNotice(message)
        }

        return result.template
    }

    @discardableResult
    @MainActor
    func revealCustomDigestTemplateInFinder(config: DigestTemplateCustomizationConfig) throws -> URL {
        try TemplateCustomization.ensureCustomTemplateFileAndRevealInFinder(
            config: config.customization,
            bundle: DigestResourceBundleLocator.bundle()
        )
    }
}
