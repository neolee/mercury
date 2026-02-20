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
        return applyPlaceholders(to: template, parameters: resolved)
    }

    func renderSystem(parameters: [String: String]) throws -> String? {
        guard let systemTemplate else {
            return nil
        }
        let resolved = mergedParameters(overrides: parameters)
        try validateRequiredPlaceholders(parameters: resolved)
        return applyPlaceholders(to: systemTemplate, parameters: resolved)
    }

    private func mergedParameters(overrides: [String: String]) -> [String: String] {
        var resolved = defaultParameters
        for (key, value) in overrides {
            resolved[key] = value
        }
        return resolved
    }

    private func validateRequiredPlaceholders(parameters: [String: String]) throws {
        for placeholder in requiredPlaceholders {
            let value = parameters[placeholder]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard value.isEmpty == false else {
                throw AgentPromptTemplateError.missingPlaceholder(name: placeholder)
            }
        }
    }

    private func applyPlaceholders(to rawTemplate: String, parameters: [String: String]) -> String {
        var rendered = rawTemplate
        for (key, value) in parameters {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"\{\{\s*\#(escapedKey)\s*\}\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
            rendered = regex.stringByReplacingMatches(in: rendered, options: [], range: range, withTemplate: value)
        }
        return rendered
    }
}

final class AgentPromptTemplateStore {
    private var templatesByID: [String: AgentPromptTemplate] = [:]

    var loadedTemplateIDs: [String] {
        templatesByID.keys.sorted()
    }

    func loadBuiltInTemplates(bundle: Bundle = .main, subdirectory: String = "AI/Templates") throws {
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
        let parsed = try parseSimpleYAML(content: content, fileName: fileName)

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

        let requiredPlaceholdersConfig = parseList(parsed["requiredPlaceholders"])
        let optionalPlaceholders = parseList(parsed["optionalPlaceholders"])
        let overlap = Set(requiredPlaceholdersConfig).intersection(optionalPlaceholders)
        guard overlap.isEmpty else {
            throw AgentPromptTemplateError.invalidTemplateFile(
                name: fileName,
                reason: "`requiredPlaceholders` and `optionalPlaceholders` overlap: \(overlap.sorted().joined(separator: ", "))."
            )
        }
        let defaultParameters = try parseParameterMap(
            parseList(parsed["defaultParameters"]),
            fileName: fileName,
            keyName: "defaultParameters"
        )

        let usedPlaceholders = extractPlaceholders(from: [templateBody, systemTemplate].compactMap { $0 }.joined(separator: "\n"))
        let unusedOptionalPlaceholders = optionalPlaceholders.filter { usedPlaceholders.contains($0) == false }
        guard unusedOptionalPlaceholders.isEmpty else {
            throw AgentPromptTemplateError.invalidTemplateFile(
                name: fileName,
                reason: "Optional placeholder(s) not found in `template`/`systemTemplate`: \(unusedOptionalPlaceholders.joined(separator: ", "))."
            )
        }

        let requiredPlaceholders: [String]
        if requiredPlaceholdersConfig.isEmpty == false {
            let missingPlaceholders = requiredPlaceholdersConfig.filter { usedPlaceholders.contains($0) == false }
            guard missingPlaceholders.isEmpty else {
                throw AgentPromptTemplateError.invalidTemplateFile(
                    name: fileName,
                    reason: "Required placeholder(s) not found in `template`/`systemTemplate`: \(missingPlaceholders.joined(separator: ", "))."
                )
            }
            requiredPlaceholders = requiredPlaceholdersConfig
        } else {
            requiredPlaceholders = usedPlaceholders
                .filter { optionalPlaceholders.contains($0) == false }
                .sorted()
        }

        return AgentPromptTemplate(
            id: id,
            version: version,
            taskType: taskType,
            requiredPlaceholders: requiredPlaceholders,
            optionalPlaceholders: optionalPlaceholders,
            defaultParameters: defaultParameters,
            systemTemplate: systemTemplate,
            template: templateBody
        )
    }

    private func parseSimpleYAML(content: String, fileName: String) throws -> [String: String] {
        var output: [String: String] = [:]
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                index += 1
                continue
            }
            guard rawLine.hasPrefix(" ") == false else {
                throw AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: "Unexpected indentation at line \(index + 1).")
            }

            guard let colonIndex = rawLine.firstIndex(of: ":") else {
                throw AgentPromptTemplateError.invalidTemplateFile(name: fileName, reason: "Invalid key-value syntax at line \(index + 1).")
            }

            let key = String(rawLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let remainderStart = rawLine.index(after: colonIndex)
            let remainder = String(rawLine[remainderStart...]).trimmingCharacters(in: .whitespaces)

            if remainder == "|" {
                index += 1
                var blockLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.hasPrefix("  ") {
                        blockLines.append(String(candidate.dropFirst(2)))
                        index += 1
                        continue
                    }
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        blockLines.append("")
                        index += 1
                        continue
                    }
                    break
                }
                output[key] = blockLines.joined(separator: "\n")
                continue
            }

            if remainder.isEmpty {
                index += 1
                var listItems: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- ") {
                        listItems.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                        index += 1
                        continue
                    }
                    if trimmed.isEmpty {
                        index += 1
                        continue
                    }
                    break
                }
                output[key] = listItems.joined(separator: "\n")
                continue
            }

            output[key] = remainder
            index += 1
        }

        return output
    }

    private func parseList(_ raw: String?) -> [String] {
        guard let raw else {
            return []
        }
        return raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private func extractPlaceholders(from template: String) -> Set<String> {
        let pattern = #"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = regex.matches(in: template, options: [], range: range)
        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: template) else {
                return nil
            }
            return String(template[tokenRange])
        })
    }

    private func parseParameterMap(
        _ items: [String],
        fileName: String,
        keyName: String
    ) throws -> [String: String] {
        var output: [String: String] = [:]
        for item in items {
            guard let separator = item.firstIndex(of: "=") else {
                throw AgentPromptTemplateError.invalidTemplateFile(
                    name: fileName,
                    reason: "`\(keyName)` item must be `key=value`, got: \(item)"
                )
            }
            let key = String(item[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false, value.isEmpty == false else {
                throw AgentPromptTemplateError.invalidTemplateFile(
                    name: fileName,
                    reason: "`\(keyName)` item must have non-empty key and value, got: \(item)"
                )
            }
            if output[key] != nil {
                throw AgentPromptTemplateError.invalidTemplateFile(
                    name: fileName,
                    reason: "`\(keyName)` contains duplicate key: \(key)"
                )
            }
            output[key] = value
        }
        return output
    }
}
