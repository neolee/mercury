//
//  TaggingPromptCustomization.swift
//  Mercury
//

import AppKit
import Foundation

enum TaggingPromptCustomizationError: LocalizedError {
    case builtInTemplateNotFound

    var errorDescription: String? {
        switch self {
        case .builtInTemplateNotFound:
            return "Built-in tagging template was not found in app resources."
        }
    }
}

enum TaggingPromptCustomization {
    static let customTemplateFileName = "tagging.yaml"
    static let builtInTemplateName = "tagging.default"
    static let builtInTemplateExtension = "yaml"
    static let templatesSubdirectory = "Agent/Prompts"
    static let templateID = "tagging.default"

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

    static func loadTaggingTemplate(
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
        let base: URL
        if let override = appSupportDirectoryOverride {
            base = override
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            base = appSupport.appendingPathComponent("Mercury/Agent/Prompts")
        }
        if createDirectoryIfNeeded {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static func resolvedBuiltInTemplateURL(
        bundle: Bundle,
        builtInTemplateURLOverride: URL?
    ) throws -> URL {
        if let override = builtInTemplateURLOverride {
            return override
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
        throw TaggingPromptCustomizationError.builtInTemplateNotFound
    }
}

extension AppModel {
    @discardableResult
    @MainActor
    func revealTaggingCustomPromptInFinder() throws -> URL {
        let fileURL = try TaggingPromptCustomization.ensureCustomTemplateFile()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return fileURL
    }
}
