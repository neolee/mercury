import Foundation
import Testing
@testable import Mercury

@Suite("Template Processing Core")
struct TemplateProcessingCoreTests {
    @Test("Name classification rejects unclassified template names")
    func nameClassificationRejectsUnclassifiedTemplateNames() throws {
        let template = """
        {{requiredName}}
        {{optionalName}}
        {{#includeNote}}
        {{optionalName}}
        {{/includeNote}}
        {{undeclaredName}}
        """

        do {
            try TemplateProcessingCore.validateNameClassification(
                variableNames: TemplateProcessingCore.extractPlaceholders(from: template, style: .plain),
                requiredPlaceholders: ["requiredName"],
                optionalPlaceholders: ["optionalName", "includeNote"],
                defaultParameters: [:],
                options: TemplateNameValidationOptions(
                    requireExplicitClassification: true,
                    conditionalSectionNames: ["includeNote"],
                    requireConditionalSectionsInOptionalPlaceholders: true,
                    requireDefaultParameterKeysInOptionalPlaceholders: true
                ),
                errorBuilder: TemplateProcessingCoreTestError.init
            )
            Issue.record("Expected explicit classification failure, but validation succeeded.")
        } catch let error as TemplateProcessingCoreTestError {
            #expect(error.message.contains("Template names must be classified"))
            #expect(error.message.contains("undeclaredName"))
        }
    }

    @Test("Name classification requires conditional sections to be optional")
    func nameClassificationRequiresConditionalSectionsToBeOptional() throws {
        do {
            try TemplateProcessingCore.validateNameClassification(
                variableNames: ["noteText"],
                requiredPlaceholders: ["noteText"],
                optionalPlaceholders: [],
                defaultParameters: [:],
                options: TemplateNameValidationOptions(
                    requireExplicitClassification: true,
                    conditionalSectionNames: ["includeNote"],
                    requireConditionalSectionsInOptionalPlaceholders: true,
                    requireDefaultParameterKeysInOptionalPlaceholders: true
                ),
                errorBuilder: TemplateProcessingCoreTestError.init
            )
            Issue.record("Expected conditional section classification failure, but validation succeeded.")
        } catch let error as TemplateProcessingCoreTestError {
            #expect(error.message.contains("Conditional section(s) must be declared"))
            #expect(error.message.contains("includeNote"))
        }
    }

    @Test("Name classification requires default keys to be optional")
    func nameClassificationRequiresDefaultKeysToBeOptional() throws {
        do {
            try TemplateProcessingCore.validateNameClassification(
                variableNames: ["labelNote"],
                requiredPlaceholders: [],
                optionalPlaceholders: [],
                defaultParameters: ["labelNote": "My Take"],
                options: TemplateNameValidationOptions(
                    requireExplicitClassification: false,
                    conditionalSectionNames: [],
                    requireConditionalSectionsInOptionalPlaceholders: false,
                    requireDefaultParameterKeysInOptionalPlaceholders: true
                ),
                errorBuilder: TemplateProcessingCoreTestError.init
            )
            Issue.record("Expected default-parameter classification failure, but validation succeeded.")
        } catch let error as TemplateProcessingCoreTestError {
            #expect(error.message.contains("`defaultParameters` keys must also be declared"))
            #expect(error.message.contains("labelNote"))
        }
    }
}

private struct TemplateProcessingCoreTestError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
