import Foundation

struct AgentPromptMessages: Sendable, Equatable {
    let systemPrompt: String
    let userPrompt: String

    var messages: [LLMMessage] {
        [
            LLMMessage(role: "system", content: systemPrompt),
            LLMMessage(role: "user", content: userPrompt)
        ]
    }
}