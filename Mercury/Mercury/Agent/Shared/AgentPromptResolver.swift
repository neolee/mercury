import AppKit
import Foundation

enum AgentPromptResolver {
    static func ensureCustomTemplateFile(
        descriptor: AgentPromptTemplateDescriptor,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> URL {
        try AgentPromptCustomization.ensureCustomTemplateFile(
            descriptor: descriptor,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
    }

    static func loadTemplate(
        descriptor: AgentPromptTemplateDescriptor,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        appSupportDirectoryOverride: URL? = nil,
        builtInTemplateURLOverride: URL? = nil
    ) throws -> TemplateCustomizationLoadResult<AgentPromptTemplate> {
        try AgentPromptCustomization.loadTemplate(
            descriptor: descriptor,
            bundle: bundle,
            fileManager: fileManager,
            appSupportDirectoryOverride: appSupportDirectoryOverride,
            builtInTemplateURLOverride: builtInTemplateURLOverride
        )
    }
}

extension AppModel {
    func loadResolvedPromptTemplate(
        descriptor: AgentPromptTemplateDescriptor,
        onNotice: @escaping (TemplateCustomizationFallbackReason) async -> Void
    ) async throws -> AgentPromptTemplate {
        let result = try AgentPromptResolver.loadTemplate(descriptor: descriptor)
        if let rejectedCustomTemplate = result.rejectedCustomTemplate {
            await MainActor.run {
                self.reportDebugIssue(
                    title: descriptor.debugTitle(for: rejectedCustomTemplate.reason),
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
    func revealPromptInFinder(descriptor: AgentPromptTemplateDescriptor) throws -> URL {
        let fileURL = try AgentPromptResolver.ensureCustomTemplateFile(descriptor: descriptor)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return fileURL
    }
}
