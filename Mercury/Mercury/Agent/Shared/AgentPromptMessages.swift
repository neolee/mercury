import Foundation

struct AgentPromptMessages: Sendable, Equatable {
    let systemPrompt: String
    let userPrompt: String

    var messages: [LLMMessage] {
        let normalizedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSystemPrompt.isEmpty {
            return [
                LLMMessage(role: "user", content: userPrompt)
            ]
        }
        return [
            LLMMessage(role: "system", content: normalizedSystemPrompt),
            LLMMessage(role: "user", content: userPrompt)
        ]
    }
}