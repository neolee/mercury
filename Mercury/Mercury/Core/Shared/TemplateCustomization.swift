import AppKit
import Foundation

struct TemplateCustomizationResourceConfig {
    let customTemplateFileName: String
    let builtInTemplateName: String
    let builtInTemplateExtension: String
    let builtInTemplatesSubdirectory: String
    let applicationSupportPathComponents: [String]
}

struct TemplateCustomizationInvalidCustomTemplate {
    let fileURL: URL
    let errorDescription: String
}

struct TemplateCustomizationLoadResult<Template> {
    let template: Template
    let invalidCustomTemplate: TemplateCustomizationInvalidCustomTemplate?
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
        loadFromFile: (URL) throws -> Template
    ) throws -> TemplateCustomizationLoadResult<Template> {
        if let customURL = try existingCustomTemplateFileURL(
            config: config,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride
        ) {
            do {
                return TemplateCustomizationLoadResult(
                    template: try loadFromFile(customURL),
                    invalidCustomTemplate: nil
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
                    invalidCustomTemplate: TemplateCustomizationInvalidCustomTemplate(
                        fileURL: customURL,
                        errorDescription: error.localizedDescription
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
            invalidCustomTemplate: nil
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

    static func invalidCustomTemplateDebugDetail(_ invalidCustomTemplate: TemplateCustomizationInvalidCustomTemplate) -> String {
        [
            "path=\(invalidCustomTemplate.fileURL.path)",
            "error=\(invalidCustomTemplate.errorDescription)",
            "action=fallback_to_built_in_template"
        ].joined(separator: "\n")
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