import Foundation

enum TemplatePlaceholderStyle: Sendable {
    case plain
    case hashPrefixed
}

struct TemplatePlaceholderContract: Sendable {
    let requiredPlaceholders: [String]
    let optionalPlaceholders: [String]
    let defaultParameters: [String: String]
}

struct TemplateNameValidationOptions: Sendable {
    let requireExplicitClassification: Bool
    let conditionalSectionNames: Set<String>
    let requireConditionalSectionsInOptionalPlaceholders: Bool
    let requireDefaultParameterKeysInOptionalPlaceholders: Bool

    init(
        requireExplicitClassification: Bool = false,
        conditionalSectionNames: Set<String> = [],
        requireConditionalSectionsInOptionalPlaceholders: Bool = false,
        requireDefaultParameterKeysInOptionalPlaceholders: Bool = false
    ) {
        self.requireExplicitClassification = requireExplicitClassification
        self.conditionalSectionNames = conditionalSectionNames
        self.requireConditionalSectionsInOptionalPlaceholders = requireConditionalSectionsInOptionalPlaceholders
        self.requireDefaultParameterKeysInOptionalPlaceholders = requireDefaultParameterKeysInOptionalPlaceholders
    }
}

enum TemplateProcessingCore {
    static func parseSimpleYAML<Failure: Error>(
        content: String,
        fileName _: String,
        errorBuilder: (String) -> Failure
    ) throws -> [String: String] {
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
                throw errorBuilder("Unexpected indentation at line \(index + 1).")
            }

            guard let colonIndex = rawLine.firstIndex(of: ":") else {
                throw errorBuilder("Invalid key-value syntax at line \(index + 1).")
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

    static func parseList(_ raw: String?) -> [String] {
        guard let raw else {
            return []
        }
        return raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    static func parseParameterMap<Failure: Error>(
        _ items: [String],
        fileName _: String,
        keyName: String,
        errorBuilder: (String) -> Failure
    ) throws -> [String: String] {
        var output: [String: String] = [:]
        for item in items {
            guard let separator = item.firstIndex(of: "=") else {
                throw errorBuilder("`\(keyName)` item must be `key=value`, got: \(item)")
            }
            let key = String(item[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false else {
                throw errorBuilder("`\(keyName)` item must have a non-empty key, got: \(item)")
            }
            if output[key] != nil {
                throw errorBuilder("`\(keyName)` contains duplicate key: \(key)")
            }
            output[key] = value
        }
        return output
    }

    static func parsePlaceholderContract<Failure: Error>(
        templateBodies: [String],
        requiredPlaceholdersRaw: String?,
        optionalPlaceholdersRaw: String?,
        defaultParametersRaw: String?,
        fileName: String,
        style: TemplatePlaceholderStyle,
        errorBuilder: (String) -> Failure
    ) throws -> TemplatePlaceholderContract {
        let requiredPlaceholdersConfig = parseList(requiredPlaceholdersRaw)
        let optionalPlaceholders = parseList(optionalPlaceholdersRaw)
        let overlap = Set(requiredPlaceholdersConfig).intersection(optionalPlaceholders)
        guard overlap.isEmpty else {
            throw errorBuilder(
                "`requiredPlaceholders` and `optionalPlaceholders` overlap: \(overlap.sorted().joined(separator: ", "))."
            )
        }

        let defaultParameters = try parseParameterMap(
            parseList(defaultParametersRaw),
            fileName: fileName,
            keyName: "defaultParameters",
            errorBuilder: errorBuilder
        )

        let combinedTemplateBodies = templateBodies.joined(separator: "\n")
        let usedPlaceholders = extractPlaceholders(
            from: combinedTemplateBodies,
            style: style
        )
        let usedSectionNames = extractSectionNames(
            from: combinedTemplateBodies,
            style: style
        )
        let declaredNames = usedPlaceholders.union(usedSectionNames)

        let unusedOptionalPlaceholders = optionalPlaceholders.filter { declaredNames.contains($0) == false }
        guard unusedOptionalPlaceholders.isEmpty else {
            throw errorBuilder(
                "Optional placeholder(s) not found in template body: \(unusedOptionalPlaceholders.joined(separator: ", "))."
            )
        }

        let requiredPlaceholders: [String]
        if requiredPlaceholdersConfig.isEmpty == false {
            let missingPlaceholders = requiredPlaceholdersConfig.filter { declaredNames.contains($0) == false }
            guard missingPlaceholders.isEmpty else {
                throw errorBuilder(
                    "Required placeholder(s) not found in template body: \(missingPlaceholders.joined(separator: ", "))."
                )
            }
            requiredPlaceholders = requiredPlaceholdersConfig
        } else {
            requiredPlaceholders = usedPlaceholders
                .filter { optionalPlaceholders.contains($0) == false }
                .sorted()
        }

        return TemplatePlaceholderContract(
            requiredPlaceholders: requiredPlaceholders,
            optionalPlaceholders: optionalPlaceholders,
            defaultParameters: defaultParameters
        )
    }

    static func validateRequiredPlaceholders<Failure: Error>(
        _ requiredPlaceholders: [String],
        parameters: [String: String],
        errorBuilder: (String) -> Failure
    ) throws {
        for placeholder in requiredPlaceholders {
            let value = parameters[placeholder]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard value.isEmpty == false else {
                throw errorBuilder(placeholder)
            }
        }
    }

    static func validateNameClassification<Failure: Error>(
        variableNames: Set<String>,
        requiredPlaceholders: [String],
        optionalPlaceholders: [String],
        defaultParameters: [String: String],
        options: TemplateNameValidationOptions,
        errorBuilder: (String) -> Failure
    ) throws {
        if options.requireConditionalSectionsInOptionalPlaceholders {
            let missingOptionalConditionalSections = options.conditionalSectionNames.filter {
                optionalPlaceholders.contains($0) == false
            }
            guard missingOptionalConditionalSections.isEmpty else {
                throw errorBuilder(
                    "Conditional section(s) must be declared in `optionalPlaceholders`: \(missingOptionalConditionalSections.sorted().joined(separator: ", "))."
                )
            }
        }

        if options.requireExplicitClassification {
            let unclassifiedNames = variableNames
                .union(options.conditionalSectionNames)
                .subtracting(requiredPlaceholders)
                .subtracting(optionalPlaceholders)
            guard unclassifiedNames.isEmpty else {
                throw errorBuilder(
                    "Template names must be classified as required or optional placeholders: \(unclassifiedNames.sorted().joined(separator: ", "))."
                )
            }
        }

        if options.requireDefaultParameterKeysInOptionalPlaceholders {
            let invalidDefaultParameterKeys = Set(defaultParameters.keys).subtracting(optionalPlaceholders)
            guard invalidDefaultParameterKeys.isEmpty else {
                throw errorBuilder(
                    "`defaultParameters` keys must also be declared in `optionalPlaceholders`: \(invalidDefaultParameterKeys.sorted().joined(separator: ", "))."
                )
            }
        }
    }

    static func extractPlaceholders(from template: String, style: TemplatePlaceholderStyle) -> Set<String> {
        let pattern: String
        switch style {
        case .plain:
            pattern = "\\{\\{\\s*([a-zA-Z0-9_]+)\\s*\\}\\}"
        case .hashPrefixed:
            pattern = "\\{\\{\\s*([a-zA-Z0-9_]+)\\s*\\}\\}"
        }

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

    static func extractSectionNames(from template: String, style: TemplatePlaceholderStyle) -> Set<String> {
        let pattern: String
        switch style {
        case .plain:
            pattern = "\\{\\{\\s*#\\s*([a-zA-Z0-9_]+)\\s*\\}\\}"
        case .hashPrefixed:
            pattern = "\\{\\{\\s*#\\s*([a-zA-Z0-9_]+)\\s*\\}\\}"
        }

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

    static func applyPlaceholders(
        to rawTemplate: String,
        parameters: [String: String],
        style: TemplatePlaceholderStyle
    ) -> String {
        var rendered = rawTemplate
        for (key, value) in parameters {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let pattern: String
            switch style {
            case .plain:
                pattern = "\\{\\{\\s*\(escapedKey)\\s*\\}\\}"
            case .hashPrefixed:
                pattern = "\\{\\{\\s*\(escapedKey)\\s*\\}\\}"
            }
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
            rendered = regex.stringByReplacingMatches(in: rendered, options: [], range: range, withTemplate: value)
        }
        return rendered
    }
}
