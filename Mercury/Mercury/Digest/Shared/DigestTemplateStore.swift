import Foundation

enum DigestTemplateError: LocalizedError {
    case directoryNotFound(String)
    case invalidTemplateFile(name: String, reason: String)
    case duplicateTemplateID(String)
    case templateNotFound(String)
    case missingPlaceholder(String)

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

nonisolated struct DigestTemplateRenderContext: Sendable {
    let scalars: [String: String]
    let repeatedSections: [String: [DigestTemplateRenderContext]]

    nonisolated init(
        scalars: [String: String] = [:],
        repeatedSections: [String: [DigestTemplateRenderContext]] = [:]
    ) {
        self.scalars = scalars
        self.repeatedSections = repeatedSections
    }
}

private enum DigestTemplateNode: Sendable {
    case text(String)
    case variable(String)
    case section(String, [DigestTemplateNode])
}

struct DigestTemplate: Sendable {
    let id: String
    let version: String
    let requiredPlaceholders: [String]
    let optionalPlaceholders: [String]
    let defaultParameters: [String: String]

    private let nodes: [DigestTemplateNode]

    init(
        id: String,
        version: String,
        requiredPlaceholders: [String],
        optionalPlaceholders: [String],
        defaultParameters: [String: String],
        templateBody: String,
        fileName: String
    ) throws {
        self.id = id
        self.version = version
        self.requiredPlaceholders = requiredPlaceholders
        self.optionalPlaceholders = optionalPlaceholders
        self.defaultParameters = defaultParameters
        self.nodes = try DigestTemplateParser.parse(template: templateBody, fileName: fileName)
    }

    func render(context: DigestTemplateRenderContext) throws -> String {
        var rootScalars = defaultParameters
        for (key, value) in context.scalars {
            rootScalars[key] = value
        }
        try TemplateProcessingCore.validateRequiredPlaceholders(requiredPlaceholders, parameters: rootScalars) {
            DigestTemplateError.missingPlaceholder($0)
        }
        let rootContext = DigestTemplateRenderContext(
            scalars: rootScalars,
            repeatedSections: context.repeatedSections
        )
        return DigestTemplateRenderer
            .render(nodes: nodes, scopes: [rootContext])
            .trimmingCharacters(in: .newlines)
    }
}

final class DigestTemplateStore {
    static let builtInSubdirectory = "Digest/Templates"
    private static let builtInFileNames: Set<String> = [
        "single-text.yaml",
        "single-markdown.yaml",
        "multiple-markdown.yaml",
        "single-text.yml",
        "single-markdown.yml",
        "multiple-markdown.yml"
    ]

    private var templatesByID: [String: DigestTemplate] = [:]

    var loadedTemplateIDs: [String] {
        templatesByID.keys.sorted()
    }

    func loadBuiltInTemplates(
        bundle: Bundle = .main,
        subdirectory: String = builtInSubdirectory
    ) throws {
        var yamlFiles: [URL] = []
        if let builtIn = bundle.urls(forResourcesWithExtension: "yaml", subdirectory: subdirectory) {
            yamlFiles.append(contentsOf: builtIn)
        }
        if let builtIn = bundle.urls(forResourcesWithExtension: "yml", subdirectory: subdirectory) {
            yamlFiles.append(contentsOf: builtIn)
        }

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
            throw DigestTemplateError.directoryNotFound(subdirectory)
        }

        try loadTemplates(fromFiles: uniqueFiles, sourceDescription: "bundle:\(bundle.bundlePath)")
    }

    func loadTemplates(from directoryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw DigestTemplateError.directoryNotFound(directoryURL.path)
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

    func template(id: String) throws -> DigestTemplate {
        guard let template = templatesByID[id] else {
            throw DigestTemplateError.templateNotFound(id)
        }
        return template
    }

    private func loadTemplates(fromFiles files: [URL], sourceDescription: String) throws {
        guard files.isEmpty == false else {
            throw DigestTemplateError.directoryNotFound(sourceDescription)
        }

        var parsedTemplates: [String: DigestTemplate] = [:]
        for fileURL in files {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let template = try parseTemplate(content: content, fileName: fileURL.lastPathComponent)
            if parsedTemplates[template.id] != nil {
                throw DigestTemplateError.duplicateTemplateID(template.id)
            }
            parsedTemplates[template.id] = template
        }

        templatesByID = parsedTemplates
    }

    private func parseTemplate(content: String, fileName: String) throws -> DigestTemplate {
        let parsed = try TemplateProcessingCore.parseSimpleYAML(
            content: content,
            fileName: fileName,
            errorBuilder: { DigestTemplateError.invalidTemplateFile(name: fileName, reason: $0) }
        )

        guard let id = parsed["id"]?.trimmingCharacters(in: .whitespacesAndNewlines), id.isEmpty == false else {
            throw DigestTemplateError.invalidTemplateFile(name: fileName, reason: "`id` is required.")
        }
        guard let version = parsed["version"]?.trimmingCharacters(in: .whitespacesAndNewlines), version.isEmpty == false else {
            throw DigestTemplateError.invalidTemplateFile(name: fileName, reason: "`version` is required.")
        }
        guard let templateBody = parsed["template"], templateBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DigestTemplateError.invalidTemplateFile(name: fileName, reason: "`template` is required.")
        }

        let placeholderContract = try TemplateProcessingCore.parsePlaceholderContract(
            templateBodies: [templateBody],
            requiredPlaceholdersRaw: parsed["requiredPlaceholders"],
            optionalPlaceholdersRaw: parsed["optionalPlaceholders"],
            defaultParametersRaw: parsed["defaultParameters"],
            fileName: fileName,
            style: .plain,
            errorBuilder: {
                DigestTemplateError.invalidTemplateFile(name: fileName, reason: $0)
            }
        )

        return try DigestTemplate(
            id: id,
            version: version,
            requiredPlaceholders: placeholderContract.requiredPlaceholders,
            optionalPlaceholders: placeholderContract.optionalPlaceholders,
            defaultParameters: placeholderContract.defaultParameters,
            templateBody: templateBody,
            fileName: fileName
        )
    }
}

private enum DigestTemplateParser {
    static func parse(template: String, fileName: String) throws -> [DigestTemplateNode] {
        var cursor = template.startIndex
        return try parseNodes(template: template, cursor: &cursor, closingSectionName: nil, fileName: fileName)
    }

    private static func parseNodes(
        template: String,
        cursor: inout String.Index,
        closingSectionName: String?,
        fileName: String
    ) throws -> [DigestTemplateNode] {
        var nodes: [DigestTemplateNode] = []

        while cursor < template.endIndex {
            guard let openRange = template.range(of: "{{", range: cursor..<template.endIndex) else {
                nodes.append(.text(String(template[cursor...])))
                cursor = template.endIndex
                break
            }

            if openRange.lowerBound > cursor {
                nodes.append(.text(String(template[cursor..<openRange.lowerBound])))
            }

            guard let closeRange = template.range(of: "}}", range: openRange.upperBound..<template.endIndex) else {
                throw DigestTemplateError.invalidTemplateFile(name: fileName, reason: "Unclosed template tag.")
            }

            let rawTag = template[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = closeRange.upperBound

            guard rawTag.isEmpty == false else {
                throw DigestTemplateError.invalidTemplateFile(name: fileName, reason: "Empty template tag is not allowed.")
            }

            if rawTag.hasPrefix("#") {
                let name = String(rawTag.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.isEmpty == false else {
                    throw DigestTemplateError.invalidTemplateFile(name: fileName, reason: "Section name must not be empty.")
                }
                let childNodes = try parseNodes(
                    template: template,
                    cursor: &cursor,
                    closingSectionName: name,
                    fileName: fileName
                )
                nodes.append(.section(name, childNodes))
                continue
            }

            if rawTag.hasPrefix("/") {
                let name = String(rawTag.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let closingSectionName else {
                    throw DigestTemplateError.invalidTemplateFile(
                        name: fileName,
                        reason: "Unexpected closing section `\(name)`."
                    )
                }
                guard name == closingSectionName else {
                    throw DigestTemplateError.invalidTemplateFile(
                        name: fileName,
                        reason: "Closing section `\(name)` does not match `\(closingSectionName)`."
                    )
                }
                return nodes
            }

            nodes.append(.variable(rawTag))
        }

        if let closingSectionName {
            throw DigestTemplateError.invalidTemplateFile(
                name: fileName,
                reason: "Unclosed section `\(closingSectionName)`."
            )
        }

        return nodes
    }
}

private enum DigestTemplateRenderer {
    static func render(nodes: [DigestTemplateNode], scopes: [DigestTemplateRenderContext]) -> String {
        var output = ""

        for node in nodes {
            switch node {
            case let .text(text):
                output += TemplateProcessingCore.applyPlaceholders(
                    to: text,
                    parameters: mergedScalars(scopes),
                    style: .plain
                )

            case let .variable(name):
                output += resolveScalar(name: name, scopes: scopes)

            case let .section(name, childNodes):
                if let repeatedScopes = resolveRepeatedSection(name: name, scopes: scopes) {
                    for repeatedScope in repeatedScopes {
                        output += render(nodes: childNodes, scopes: [repeatedScope] + scopes)
                    }
                    continue
                }

                if resolveSectionTruthiness(name: name, scopes: scopes) {
                    output += render(nodes: childNodes, scopes: scopes)
                }
            }
        }

        return output
    }

    private static func mergedScalars(_ scopes: [DigestTemplateRenderContext]) -> [String: String] {
        var merged: [String: String] = [:]
        for scope in scopes.reversed() {
            for (key, value) in scope.scalars {
                merged[key] = value
            }
        }
        return merged
    }

    private static func resolveScalar(name: String, scopes: [DigestTemplateRenderContext]) -> String {
        for scope in scopes {
            if let value = scope.scalars[name] {
                return value
            }
        }
        return ""
    }

    private static func resolveRepeatedSection(
        name: String,
        scopes: [DigestTemplateRenderContext]
    ) -> [DigestTemplateRenderContext]? {
        for scope in scopes {
            if let repeated = scope.repeatedSections[name] {
                return repeated
            }
        }
        return nil
    }

    private static func resolveSectionTruthiness(
        name: String,
        scopes: [DigestTemplateRenderContext]
    ) -> Bool {
        for scope in scopes {
            if let value = scope.scalars[name] {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }
        return false
    }
}
