import Foundation

enum AgentPromptTemplateError: LocalizedError {
    case directoryNotFound(String)
    case invalidTemplateFile(name: String, reason: String)
    case duplicateTemplateID(String)
    case templateNotFound(String)
    case missingPlaceholder(name: String)

    var errorDescription: String? {
        switch self {
        case let .directoryNotFound(path):
            return "Template directory not found: \(path)"
        case let .invalidTemplateFile(name, reason):
            return "Invalid template file \(name): \(reason)"
        case let .duplicateTemplateID(id):
            return "Duplicate template id found: \(id)"
        case let .templateNotFound(id):
            return "Template not found for id: \(id)"
        case let .missingPlaceholder(name):
            return "Missing required template parameter: \(name)"
        }
    }
}

struct AgentPromptTemplate: Sendable {
    let id: String
    let version: String
    let taskType: AgentTaskType
    let requiredPlaceholders: [String]
    let optionalPlaceholders: [String]
    let defaultParameters: [String: String]
    let systemTemplate: String?
    let template: String

    func render(parameters: [String: String]) throws -> String {
        let resolved = mergedParameters(overrides: parameters)
        try validateRequiredPlaceholders(parameters: resolved)
        return TemplateProcessingCore.applyPlaceholders(
            to: template,
            parameters: resolved,
            style: .hashPrefixed
        )
    }

    func renderSystem(parameters: [String: String]) throws -> String? {
        guard let systemTemplate else {
            return nil
        }
        let resolved = mergedParameters(overrides: parameters)
        try validateRequiredPlaceholders(parameters: resolved)
        return TemplateProcessingCore.applyPlaceholders(
            to: systemTemplate,
            parameters: resolved,
            style: .hashPrefixed
        )
    }

    private func mergedParameters(overrides: [String: String]) -> [String: String] {
        var resolved = defaultParameters
        for (key, value) in overrides {
            resolved[key] = value
        }
        return resolved
    }

    private func validateRequiredPlaceholders(parameters: [String: String]) throws {
        try TemplateProcessingCore.validateRequiredPlaceholders(requiredPlaceholders, parameters: parameters) {
            AgentPromptTemplateError.missingPlaceholder(name: $0)
        }
    }
}

final class AgentPromptTemplateStore {
    private static let builtInFileNames: Set<String> = [
        "summary.default.yaml",
        "summary.default.yml",
        "tagging.default.yaml",
        "tagging.default.yml",
        "translation.default.yaml",
        "translation.default.yml"
    ]

    private var templatesByID: [String: AgentPromptTemplate] = [:]

    var loadedTemplateIDs: [String] {
        templatesByID.keys.sorted()
    }

    func loadBuiltInTemplates(bundle: Bundle = .main, subdirectory: String = "Agent/Prompts") throws {
        var yamlFiles: [URL] = []
        if let builtIn = bundle.urls(forResourcesWithExtension: "yaml", subdirectory: subdirectory) {
            yamlFiles.append(contentsOf: builtIn)
        }
        if let builtIn = bundle.urls(forResourcesWithExtension: "yml", subdirectory: subdirectory) {
            yamlFiles.append(contentsOf: builtIn)
        }

        // Fallback for file-system-synchronized projects where nested resource
        // folders can be flattened by the app bundle copy step.
        if yamlFiles.isEmpty {
            if let rootYAML = bundle.urls(forResourcesWithExtension: "yaml", subdirectory: nil) {
                yamlFiles.append(contentsOf: rootYAML)
            }
            if let rootYML = bundle.urls(forResourcesWithExtension: "yml", subdirectory: nil) {
                yamlFiles.append(contentsOf: rootYML)
            }
        }

        let uniqueFiles = Array(Set(yamlFiles))
            .filter { Self.builtInFileNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard uniqueFiles.isEmpty == false else {
            throw AgentPromptTemplateError.directoryNotFound(subdirectory)
        }

        try loadTemplates(fromFiles: uniqueFiles, sourceDescription: "bundle:\(bundle.bundlePath)")
    }

    func loadTemplates(from directoryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw AgentPromptTemplateError.directoryNotFound(directoryURL.path)
        }

        let yamlFiles = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        try loadTemplates(fromFiles: yamlFiles, sourceDescription: directoryURL.path)
    }

    func loadTemplate(from fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentPromptTemplateError.directoryNotFound(fileURL.path)
        }
        try loadTemplates(fromFiles: [fileURL], sourceDescription: fileURL.path)
    }

    private func loadTemplates(fromFiles files: [URL], sourceDescription: String) throws {
        guard files.isEmpty == false else {
            throw AgentPromptTemplateError.directoryNotFound(sourceDescription)
        }

        var parsedTemplates: [String: AgentPromptTemplate] = [:]
        for fileURL in files {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let template = try parseTemplate(content: content, fileName: fileURL.lastPathComponent)
            if parsedTemplates[template.id] != nil {
                throw AgentPromptTemplateError.duplicateTemplateID(template.id)
            }
            parsedTemplates[template.id] = template
        }

        templatesByID = parsedTemplates
    }

    func template(id: String) throws -> AgentPromptTemplate {
        guard let template = templatesByID[id] else {
            throw AgentPromptTemplateError.templateNotFound(id)
        }
        return template
    }

    private func parseTemplate(content: String, fileName: String) throws -> AgentPromptTemplate {
        let parsed = try TemplateProcessingCore.parseSimpleYAML(
            content: content,
            fileName: fileName,
            errorBuilder: { AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: $0) }
        )

        guard let id = parsed["id"]?.trimmingCharacters(in: .whitespacesAndNewlines), id.isEmpty == false else {
            throw AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: "`id` is required.")
        }
        guard let version = parsed["version"]?.trimmingCharacters(in: .whitespacesAndNewlines), version.isEmpty == false else {
            throw AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: "`version` is required.")
        }
        guard let taskTypeRaw = parsed["taskType"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let taskType = AgentTaskType(rawValue: taskTypeRaw) else {
            throw AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: "`taskType` must be one of: tagging, summary, translation.")
        }
        guard let templateBody = parsed["template"], templateBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: "`template` is required.")
        }
        let systemTemplate = parsed["systemTemplate"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? parsed["systemTemplate"]
            : nil

        let placeholderContract = try TemplateProcessingCore.parsePlaceholderContract(
            templateBodies: [templateBody, systemTemplate].compactMap { $0 },
            requiredPlaceholdersRaw: parsed["requiredPlaceholders"],
            optionalPlaceholdersRaw: parsed["optionalPlaceholders"],
            defaultParametersRaw: parsed["defaultParameters"],
            fileName: fileName,
            style: .hashPrefixed,
            errorBuilder: {
                AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: $0)
            }
        )

        return AgentPromptTemplate(
            id: id,
            version: version,
            taskType: taskType,
            requiredPlaceholders: placeholderContract.requiredPlaceholders,
            optionalPlaceholders: placeholderContract.optionalPlaceholders,
            defaultParameters: placeholderContract.defaultParameters,
            systemTemplate: systemTemplate,
            template: templateBody
        )
    }
}
