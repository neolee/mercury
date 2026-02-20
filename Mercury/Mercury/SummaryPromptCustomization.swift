import AppKit
import Foundation

enum SummaryPromptCustomizationError: LocalizedError {
    case builtInTemplateNotFound

    var errorDescription: String? {
        switch self {
        case .builtInTemplateNotFound:
            return "Built-in summary template was not found in app resources."
        }
    }
}

enum SummaryPromptCustomization {
    static let customTemplateFileName = "summary.yaml"
    static let builtInTemplateName = "summary.default"
    static let builtInTemplateExtension = "yaml"
    static let templatesSubdirectory = "AI/Templates"
    static let templateID = "summary.default"

    static func customTemplateFileURL(
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        createDirectoryIfNeeded: Bool = true
    ) throws -> URL {
        let directory = try customTemplateDirectoryURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: createDirectoryIfNeeded
        )
        return directory.appendingPathComponent(customTemplateFileName)
    }

    static func ensureCustomTemplateFile(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> URL {
        let destination = try customTemplateFileURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            createDirectoryIfNeeded: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        let sourceURL = try resolvedBuiltInTemplateURL(
            bundle: bundle,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func loadSummaryTemplate(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> AgentPromptTemplate {
        if let customURL = try existingCustomTemplateFileURL(
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride
        ) {
            let store = AgentPromptTemplateStore()
            try store.loadTemplate(from: customURL)
            return try store.template(id: templateID)
        }

        if let builtInTemplateURLOverride {
            let store = AgentPromptTemplateStore()
            try store.loadTemplate(from: builtInTemplateURLOverride)
            return try store.template(id: templateID)
        }

        let store = AgentPromptTemplateStore()
        try store.loadBuiltInTemplates(bundle: bundle, subdirectory: templatesSubdirectory)
        return try store.template(id: templateID)
    }

    private static func existingCustomTemplateFileURL(
        fileManager: FileManager,
        appSupportDirectoryOverride: URL?
    ) throws -> URL? {
        let url = try customTemplateFileURL(
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

        let mercuryDirectory = appSupport.appendingPathComponent("Mercury", isDirectory: true)
        let templatesDirectory = mercuryDirectory
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
        if createDirectoryIfNeeded {
            try fileManager.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        }
        return templatesDirectory
    }

    private static func resolvedBuiltInTemplateURL(
        bundle: Bundle,
        builtInTemplateURLOverride: URL?
    ) throws -> URL {
        if let builtInTemplateURLOverride {
            return builtInTemplateURLOverride
        }

        if let url = bundle.url(
            forResource: builtInTemplateName,
            withExtension: builtInTemplateExtension,
            subdirectory: templatesSubdirectory
        ) {
            return url
        }
        if let url = bundle.url(
            forResource: builtInTemplateName,
            withExtension: builtInTemplateExtension,
            subdirectory: nil
        ) {
            return url
        }
        throw SummaryPromptCustomizationError.builtInTemplateNotFound
    }
}

extension AppModel {
    @discardableResult
    @MainActor
    func revealSummaryCustomPromptInFinder() throws -> URL {
        let fileURL = try SummaryPromptCustomization.ensureCustomTemplateFile()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return fileURL
    }
}
