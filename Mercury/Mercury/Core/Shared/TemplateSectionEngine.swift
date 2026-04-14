import Foundation

nonisolated struct TemplateRenderContext: Sendable {
    let scalars: [String: String]
    let repeatedSections: [String: [TemplateRenderContext]]

    init(
        scalars: [String: String] = [:],
        repeatedSections: [String: [TemplateRenderContext]] = [:]
    ) {
        self.scalars = scalars
        self.repeatedSections = repeatedSections
    }
}

nonisolated enum TemplateNode: Sendable {
    case text(String)
    case variable(String)
    case section(String, [TemplateNode])
}

nonisolated struct TemplateSectionPolicy: Sendable {
    let allowsSections: Bool
    let allowsNestedSections: Bool

    static let agentPrompt = TemplateSectionPolicy(
        allowsSections: true,
        allowsNestedSections: false
    )

    static let digest = TemplateSectionPolicy(
        allowsSections: true,
        allowsNestedSections: true
    )
}

nonisolated enum TemplateSectionEngine {
    static func parse<Failure: Error>(
        template: String,
        fileName: String,
        policy: TemplateSectionPolicy,
        errorBuilder: (String) -> Failure
    ) throws -> [TemplateNode] {
        var cursor = template.startIndex
        return try parseNodes(
            template: template,
            cursor: &cursor,
            closingSectionName: nil,
            fileName: fileName,
            policy: policy,
            errorBuilder: errorBuilder
        )
    }

    static func render(
        nodes: [TemplateNode],
        scopes: [TemplateRenderContext],
        style: TemplatePlaceholderStyle,
        repeatedSectionNames: Set<String> = []
    ) -> String {
        var output = ""

        for node in nodes {
            switch node {
            case let .text(text):
                output += TemplateProcessingCore.applyPlaceholders(
                    to: text,
                    parameters: mergedScalars(scopes),
                    style: style
                )

            case let .variable(name):
                output += resolveScalar(name: name, scopes: scopes)

            case let .section(name, childNodes):
                if repeatedSectionNames.contains(name),
                   let repeatedScopes = resolveRepeatedSection(name: name, scopes: scopes) {
                    for repeatedScope in repeatedScopes {
                        output += render(
                            nodes: childNodes,
                            scopes: [repeatedScope] + scopes,
                            style: style,
                            repeatedSectionNames: repeatedSectionNames
                        )
                    }
                    continue
                }

                if resolveSectionTruthiness(name: name, scopes: scopes) {
                    output += render(
                        nodes: childNodes,
                        scopes: scopes,
                        style: style,
                        repeatedSectionNames: repeatedSectionNames
                    )
                }
            }
        }

        return output
    }

    private static func parseNodes<Failure: Error>(
        template: String,
        cursor: inout String.Index,
        closingSectionName: String?,
        fileName: String,
        policy: TemplateSectionPolicy,
        errorBuilder: (String) -> Failure
    ) throws -> [TemplateNode] {
        var nodes: [TemplateNode] = []

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
                throw errorBuilder("Unclosed template tag.")
            }

            let rawTag = template[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = closeRange.upperBound

            guard rawTag.isEmpty == false else {
                throw errorBuilder("Empty template tag is not allowed.")
            }

            if rawTag.hasPrefix("#") {
                guard policy.allowsSections else {
                    throw errorBuilder("Template sections are not supported.")
                }
                if policy.allowsNestedSections == false, closingSectionName != nil {
                    throw errorBuilder("Nested sections are not supported.")
                }

                let name = String(rawTag.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.isEmpty == false else {
                    throw errorBuilder("Section name must not be empty.")
                }
                let childNodes = try parseNodes(
                    template: template,
                    cursor: &cursor,
                    closingSectionName: name,
                    fileName: fileName,
                    policy: policy,
                    errorBuilder: errorBuilder
                )
                nodes.append(.section(name, childNodes))
                continue
            }

            if rawTag.hasPrefix("/") {
                let name = String(rawTag.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let closingSectionName else {
                    throw errorBuilder("Unexpected closing section `\(name)`.")
                }
                guard name == closingSectionName else {
                    throw errorBuilder("Closing section `\(name)` does not match `\(closingSectionName)`.")
                }
                return nodes
            }

            nodes.append(.variable(String(rawTag)))
        }

        if let closingSectionName {
            throw errorBuilder("Unclosed section `\(closingSectionName)`.")
        }

        return nodes
    }

    private static func mergedScalars(_ scopes: [TemplateRenderContext]) -> [String: String] {
        var merged: [String: String] = [:]
        for scope in scopes.reversed() {
            for (key, value) in scope.scalars {
                merged[key] = value
            }
        }
        return merged
    }

    private static func resolveScalar(name: String, scopes: [TemplateRenderContext]) -> String {
        for scope in scopes {
            if let value = scope.scalars[name] {
                return value
            }
        }
        return ""
    }

    private static func resolveRepeatedSection(
        name: String,
        scopes: [TemplateRenderContext]
    ) -> [TemplateRenderContext]? {
        for scope in scopes {
            if let repeated = scope.repeatedSections[name] {
                return repeated
            }
        }
        return nil
    }

    private static func resolveSectionTruthiness(
        name: String,
        scopes: [TemplateRenderContext]
    ) -> Bool {
        for scope in scopes {
            if let value = scope.scalars[name] {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }
        return false
    }
}
