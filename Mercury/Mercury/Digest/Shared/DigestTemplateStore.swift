import Foundation

enum DigestTemplateError: LocalizedError {
    case directoryNotFound(String)
    case invalidTemplateFile(name: String, reason: String)
    case duplicateTemplateID(String)
    case templateNotFound(String)
    case missingPlaceholder(String)
    case missingRepeatedSection(String)

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
        case let .missingRepeatedSection(name):
            return "Missing required repeated section: \(name)"
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

struct DigestTemplate: Sendable {
    let id: String
    let version: String
    let requiredPlaceholders: [String]
    let optionalPlaceholders: [String]
    let defaultParameters: [String: String]
    let repeatedSectionNames: [String]

    private let nodes: [TemplateNode]

    init(
        id: String,
        version: String,
        requiredPlaceholders: [String],
        optionalPlaceholders: [String],
        defaultParameters: [String: String],
        repeatedSectionNames: [String],
        templateBody: String,
        fileName: String
    ) throws {
        self.id = id
        self.version = version
        self.requiredPlaceholders = requiredPlaceholders
        self.optionalPlaceholders = optionalPlaceholders
        self.defaultParameters = defaultParameters
        self.repeatedSectionNames = repeatedSectionNames
        self.nodes = try TemplateSectionEngine.parse(
            template: templateBody,
            fileName: fileName,
            policy: .digest,
            errorBuilder: {
                DigestTemplateError.invalidTemplateFile(name: fileName, reason: $0)
            }
        )
    }

    func render(context: DigestTemplateRenderContext) throws -> String {
        var rootScalars = defaultParameters
        for (key, value) in context.scalars {
            rootScalars[key] = value
        }
        let requiredScalarPlaceholders = requiredPlaceholders.filter { repeatedSectionNames.contains($0) == false }
        try TemplateProcessingCore.validateRequiredPlaceholders(requiredScalarPlaceholders, parameters: rootScalars) {
            DigestTemplateError.missingPlaceholder($0)
        }
        try validateRequiredRepeatedSections(repeatedSectionNames, context: context)
        let rootContext = DigestTemplateRenderContext(
            scalars: rootScalars,
            repeatedSections: context.repeatedSections
        )
        return TemplateSectionEngine
            .render(
                nodes: nodes,
                scopes: [rootContext.templateRenderContext],
                style: .plain,
                repeatedSectionNames: Set(repeatedSectionNames)
            )
            .trimmingCharacters(in: .newlines)
    }

    private func validateRequiredRepeatedSections(
        _ repeatedSectionNames: [String],
        context: DigestTemplateRenderContext
    ) throws {
        for name in repeatedSectionNames where context.repeatedSections[name] == nil {
            throw DigestTemplateError.missingRepeatedSection(name)
        }
    }
}

final class DigestTemplateStore {
    nonisolated static let builtInSubdirectory = "Digest/Templates"
    nonisolated private static let builtInFileNames: Set<String> = [
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

    func loadTemplate(from fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DigestTemplateError.directoryNotFound(fileURL.path)
        }
        try loadTemplates(fromFiles: [fileURL], sourceDescription: fileURL.path)
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
        let repeatedSectionNames = TemplateProcessingCore.parseList(parsed["repeatedSectionNames"])
        let sectionNames = TemplateProcessingCore.extractSectionNames(from: templateBody, style: .plain)
        let variableNames = TemplateProcessingCore.extractPlaceholders(from: templateBody, style: .plain)
        let placeholderNames = Set(placeholderContract.optionalPlaceholders)
            .union(placeholderContract.defaultParameters.keys)
        let repeatedSectionOverlap = Set(repeatedSectionNames).intersection(placeholderNames)
        guard repeatedSectionOverlap.isEmpty else {
            throw DigestTemplateError.invalidTemplateFile(
                name: fileName,
                reason: "`repeatedSectionNames` overlap scalar placeholders or defaults: \(repeatedSectionOverlap.sorted().joined(separator: ", "))."
            )
        }
        let missingRepeatedSections = repeatedSectionNames.filter { sectionNames.contains($0) == false }
        guard missingRepeatedSections.isEmpty else {
            throw DigestTemplateError.invalidTemplateFile(
                name: fileName,
                reason: "Repeated section(s) not found in template body: \(missingRepeatedSections.joined(separator: ", "))."
            )
        }
        let missingRequiredRepeatedSections = repeatedSectionNames.filter {
            placeholderContract.requiredPlaceholders.contains($0) == false
        }
        guard missingRequiredRepeatedSections.isEmpty else {
            throw DigestTemplateError.invalidTemplateFile(
                name: fileName,
                reason: "Repeated section(s) must also be declared in `requiredPlaceholders`: \(missingRequiredRepeatedSections.joined(separator: ", "))."
            )
        }
        let nonRepeatedSectionNames = sectionNames.subtracting(repeatedSectionNames)
        try TemplateProcessingCore.validateNameClassification(
            variableNames: variableNames,
            requiredPlaceholders: placeholderContract.requiredPlaceholders,
            optionalPlaceholders: placeholderContract.optionalPlaceholders,
            defaultParameters: placeholderContract.defaultParameters,
            options: TemplateNameValidationOptions(
                requireExplicitClassification: true,
                conditionalSectionNames: nonRepeatedSectionNames,
                requireConditionalSectionsInOptionalPlaceholders: true,
                requireDefaultParameterKeysInOptionalPlaceholders: true
            ),
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
            repeatedSectionNames: repeatedSectionNames,
            templateBody: templateBody,
            fileName: fileName
        )
    }
}

private extension DigestTemplateRenderContext {
    var templateRenderContext: TemplateRenderContext {
        TemplateRenderContext(
            scalars: scalars,
            repeatedSections: repeatedSections.mapValues { contexts in
                contexts.map(\.templateRenderContext)
            }
        )
    }
}
