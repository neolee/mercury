import AppKit
import Foundation

enum AgentPromptResolutionContext: Sendable, Equatable {
    case summary
    case translation(strategy: TranslationPromptStrategy)
    case tagging

    var customizationConfig: AgentPromptCustomizationConfig {
        switch self {
        case .summary:
            return .summary
        case .translation:
            return .translation
        case .tagging:
            return .tagging
        }
    }

    var builtInTemplateID: String {
        switch self {
        case .summary:
            return AgentPromptCustomizationConfig.summary.templateID
        case .translation(let strategy):
            switch strategy {
            case .standard:
                return AgentPromptCustomizationConfig.translation.templateID
            case .hyMTOptimized:
                return "translation.hy-mt"
            }
        case .tagging:
            return AgentPromptCustomizationConfig.tagging.templateID
        }
    }

    var builtInTemplateName: String {
        switch self {
        case .summary:
            return AgentPromptCustomizationConfig.summary.builtInTemplateName
        case .translation(let strategy):
            switch strategy {
            case .standard:
                return AgentPromptCustomizationConfig.translation.builtInTemplateName
            case .hyMTOptimized:
                return "translation.hy-mt"
            }
        case .tagging:
            return AgentPromptCustomizationConfig.tagging.builtInTemplateName
        }
    }
}

struct AgentPromptResolutionResult: Sendable {
    let template: AgentPromptTemplate
    let rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate?
}

enum AgentPromptResolver {
    static func ensureCustomTemplateFile(
        context: AgentPromptResolutionContext,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplatesDirectoryOverride: URL? = nil
    ) throws -> URL {
        let builtInTemplateURL = try resolvedBuiltInTemplateURL(
            context: context,
            bundle: bundle,
            builtInTemplatesDirectoryOverride: builtInTemplatesDirectoryOverride
        )
        return try AgentPromptCustomization.ensureCustomTemplateFile(
            config: context.customizationConfig,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURL,
            builtInTemplateContentTransform: { builtInContent in
                normalizedCustomTemplateContent(
                    builtInContent,
                    targetTemplateID: context.customizationConfig.templateID
                )
            }
        )
    }

    static func loadTemplate(
        context: AgentPromptResolutionContext,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplatesDirectoryOverride: URL? = nil
    ) throws -> AgentPromptResolutionResult {
        let builtInTemplate = try loadBuiltInTemplate(
            id: context.builtInTemplateID,
            bundle: bundle,
            builtInTemplatesDirectoryOverride: builtInTemplatesDirectoryOverride
        )

        if let customURL = try existingCustomTemplateFileURL(
            config: context.customizationConfig,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride
        ) {
            do {
                let customTemplate = try loadCustomTemplate(
                    fileURL: customURL,
                    config: context.customizationConfig
                )
                if customTemplate.version != builtInTemplate.version {
                    return AgentPromptResolutionResult(
                        template: builtInTemplate,
                        rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate(
                            fileURL: customURL,
                            errorDescription: "Custom template version \(customTemplate.version) does not match built-in version \(builtInTemplate.version).",
                            reason: .versionMismatch(
                                customVersion: customTemplate.version,
                                builtInVersion: builtInTemplate.version
                            )
                        )
                    )
                }
                return AgentPromptResolutionResult(
                    template: customTemplate,
                    rejectedCustomTemplate: nil
                )
            } catch {
                return AgentPromptResolutionResult(
                    template: builtInTemplate,
                    rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate(
                        fileURL: customURL,
                        errorDescription: error.localizedDescription,
                        reason: .invalidCustomTemplate
                    )
                )
            }
        }

        return AgentPromptResolutionResult(template: builtInTemplate, rejectedCustomTemplate: nil)
    }

    private static func existingCustomTemplateFileURL(
        config: AgentPromptCustomizationConfig,
        fileManager: FileManager,
        appSupportDirectoryOverride: URL?
    ) throws -> URL? {
        let customURL = try AgentPromptCustomization.customTemplateFileURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: false
        )
        return fileManager.fileExists(atPath: customURL.path) ? customURL : nil
    }

    private static func loadCustomTemplate(
        fileURL: URL,
        config: AgentPromptCustomizationConfig
    ) throws -> AgentPromptTemplate {
        let store = AgentPromptTemplateStore()
        try store.loadTemplate(from: fileURL)
        return try store.template(id: config.templateID)
    }

    private static func loadBuiltInTemplate(
        id: String,
        bundle: Bundle,
        builtInTemplatesDirectoryOverride: URL?
    ) throws -> AgentPromptTemplate {
        let store = AgentPromptTemplateStore()
        if let builtInTemplatesDirectoryOverride {
            try store.loadTemplates(from: builtInTemplatesDirectoryOverride)
        } else {
            try store.loadBuiltInTemplates(bundle: bundle)
        }
        return try store.template(id: id)
    }

    private static func resolvedBuiltInTemplateURL(
        context: AgentPromptResolutionContext,
        bundle: Bundle,
        builtInTemplatesDirectoryOverride: URL?
    ) throws -> URL {
        if let builtInTemplatesDirectoryOverride {
            let yamlURL = builtInTemplatesDirectoryOverride.appendingPathComponent("\(context.builtInTemplateName).yaml")
            if FileManager.default.fileExists(atPath: yamlURL.path) {
                return yamlURL
            }
            let ymlURL = builtInTemplatesDirectoryOverride.appendingPathComponent("\(context.builtInTemplateName).yml")
            if FileManager.default.fileExists(atPath: ymlURL.path) {
                return ymlURL
            }
            throw TemplateCustomizationError.builtInTemplateNotFound(name: context.builtInTemplateName)
        }

        if let url = bundle.url(
            forResource: context.builtInTemplateName,
            withExtension: AgentPromptCustomizationConfig.builtInTemplateExtension,
            subdirectory: AgentPromptCustomizationConfig.templatesSubdirectory
        ) {
            return url
        }

        if let url = bundle.url(
            forResource: context.builtInTemplateName,
            withExtension: AgentPromptCustomizationConfig.builtInTemplateExtension,
            subdirectory: nil
        ) {
            return url
        }

        throw TemplateCustomizationError.builtInTemplateNotFound(name: context.builtInTemplateName)
    }

    private static func normalizedCustomTemplateContent(
        _ builtInContent: String,
        targetTemplateID: String
    ) -> String {
        let pattern = #"(?m)^id:\s*.+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return builtInContent
        }
        let range = NSRange(builtInContent.startIndex..<builtInContent.endIndex, in: builtInContent)
        let replacement = "id: \(targetTemplateID)"
        return regex.stringByReplacingMatches(
            in: builtInContent,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

extension AppModel {
    func loadResolvedPromptTemplate(
        context: AgentPromptResolutionContext,
        onNotice: @escaping (TemplateCustomizationFallbackReason) async -> Void
    ) async throws -> AgentPromptTemplate {
        let result = try AgentPromptResolver.loadTemplate(context: context)
        if let rejectedCustomTemplate = result.rejectedCustomTemplate {
            await MainActor.run {
                self.reportDebugIssue(
                    title: context.customizationConfig.debugTitle(for: rejectedCustomTemplate.reason),
                    detail: TemplateCustomization.rejectedCustomTemplateDebugDetail(rejectedCustomTemplate),
                    category: .task
                )
            }
            await onNotice(rejectedCustomTemplate.reason)
        }
        return result.template
    }

    @discardableResult
    @MainActor
    func revealPromptInFinder(context: AgentPromptResolutionContext) throws -> URL {
        let fileURL = try AgentPromptResolver.ensureCustomTemplateFile(context: context)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return fileURL
    }
}