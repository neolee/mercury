import AppKit
import Foundation

nonisolated enum TemplateCustomizationFallbackReason: Sendable, Equatable {
    case invalidCustomTemplate
    case versionMismatch(customVersion: String, builtInVersion: String)
}

struct TemplateCustomizationResourceConfig {
    let customTemplateFileName: String
    let builtInTemplateName: String
    let builtInTemplateExtension: String
    let builtInTemplatesSubdirectory: String
    let applicationSupportPathComponents: [String]
}

struct TemplateCustomizationRejectedCustomTemplate {
    let fileURL: URL
    let errorDescription: String
    let reason: TemplateCustomizationFallbackReason
}

struct TemplateCustomizationLoadResult<Template> {
    let template: Template
    let rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate?
}

enum TemplateCustomizationError: LocalizedError {
    case builtInTemplateNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case let .builtInTemplateNotFound(name):
            return "Built-in template was not found in app resources: \(name)"
        }
    }
}

enum TemplateCustomization {
    static func customTemplateFileURL(
        config: TemplateCustomizationResourceConfig,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        createDirectoryIfNeeded: Bool = true
    ) throws -> URL {
        let directory = try customTemplateDirectoryURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: createDirectoryIfNeeded
        )
        return directory.appendingPathComponent(config.customTemplateFileName)
    }

    static func ensureCustomTemplateFile(
        config: TemplateCustomizationResourceConfig,
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

    static func loadTemplate<Template>(
        config: TemplateCustomizationResourceConfig,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil,
        templateVersion: (Template) -> String,
        loadFromFile: (URL) throws -> Template
    ) throws -> TemplateCustomizationLoadResult<Template> {
        if let customURL = try existingCustomTemplateFileURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride
        ) {
            do {
                let customTemplate = try loadFromFile(customURL)
                let builtInTemplate = try loadBuiltInTemplate(
                    config: config,
                    bundle: bundle,
                    builtInTemplateURLOverride: builtInTemplateURLOverride,
                    loadFromFile: loadFromFile
                )
                let customVersion = templateVersion(customTemplate)
                let builtInVersion = templateVersion(builtInTemplate)
                if customVersion != builtInVersion {
                    return TemplateCustomizationLoadResult(
                        template: builtInTemplate,
                        rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate(
                            fileURL: customURL,
                            errorDescription: "Custom template version \(customVersion) does not match built-in version \(builtInVersion).",
                            reason: .versionMismatch(
                                customVersion: customVersion,
                                builtInVersion: builtInVersion
                            )
                        )
                    )
                }
                return TemplateCustomizationLoadResult(
                    template: customTemplate,
                    rejectedCustomTemplate: nil
                )
            } catch {
                let builtInTemplate = try loadBuiltInTemplate(
                    config: config,
                    bundle: bundle,
                    builtInTemplateURLOverride: builtInTemplateURLOverride,
                    loadFromFile: loadFromFile
                )
                return TemplateCustomizationLoadResult(
                    template: builtInTemplate,
                    rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate(
                        fileURL: customURL,
                        errorDescription: error.localizedDescription,
                        reason: .invalidCustomTemplate
                    )
                )
            }
        }

        return TemplateCustomizationLoadResult(
            template: try loadBuiltInTemplate(
                config: config,
                bundle: bundle,
                builtInTemplateURLOverride: builtInTemplateURLOverride,
                loadFromFile: loadFromFile
            ),
            rejectedCustomTemplate: nil
        )
    }

    @discardableResult
    @MainActor
    static func ensureCustomTemplateFileAndRevealInFinder(
        config: TemplateCustomizationResourceConfig,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> URL {
        let fileURL = try ensureCustomTemplateFile(
            config: config,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return fileURL
    }

    static func rejectedCustomTemplateDebugDetail(_ rejectedCustomTemplate: TemplateCustomizationRejectedCustomTemplate) -> String {
        var lines = [
            "path=\(rejectedCustomTemplate.fileURL.path)",
            "error=\(rejectedCustomTemplate.errorDescription)",
            "action=fallback_to_built_in_template"
        ]
        switch rejectedCustomTemplate.reason {
        case .invalidCustomTemplate:
            lines.append("reason=invalid_custom_template")
        case .versionMismatch(let customVersion, let builtInVersion):
            lines.append("reason=version_mismatch")
            lines.append("customVersion=\(customVersion)")
            lines.append("builtInVersion=\(builtInVersion)")
        }
        return lines.joined(separator: "\n")
    }

    private static func existingCustomTemplateFileURL(
        config: TemplateCustomizationResourceConfig,
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

    private static func loadBuiltInTemplate<Template>(
        config: TemplateCustomizationResourceConfig,
        bundle: Bundle,
        builtInTemplateURLOverride: URL?,
        loadFromFile: (URL) throws -> Template
    ) throws -> Template {
        try loadFromFile(
            resolvedBuiltInTemplateURL(
                config: config,
                bundle: bundle,
                builtInTemplateURLOverride: builtInTemplateURLOverride
            )
        )
    }

    private static func customTemplateDirectoryURL(
        config: TemplateCustomizationResourceConfig,
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

        let templatesDirectory = config.applicationSupportPathComponents.reduce(appSupport) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }

        if createDirectoryIfNeeded {
            try fileManager.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        }
        return templatesDirectory
    }

    private static func resolvedBuiltInTemplateURL(
        config: TemplateCustomizationResourceConfig,
        bundle: Bundle,
        builtInTemplateURLOverride: URL?
    ) throws -> URL {
        if let builtInTemplateURLOverride {
            return builtInTemplateURLOverride
        }

        if let url = bundle.url(
            forResource: config.builtInTemplateName,
            withExtension: config.builtInTemplateExtension,
            subdirectory: config.builtInTemplatesSubdirectory
        ) {
            return url
        }

        if let url = bundle.url(
            forResource: config.builtInTemplateName,
            withExtension: config.builtInTemplateExtension,
            subdirectory: nil
        ) {
            return url
        }

        throw TemplateCustomizationError.builtInTemplateNotFound(name: config.builtInTemplateName)
    }
}
