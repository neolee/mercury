//
//  AIProviderValidation.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation

struct AgentProviderValidationUseCase {
    let provider: any LLMProvider
    let credentialStore: CredentialStore

    func testConnection(
        baseURL: String,
        apiKey: String,
        model: String,
        isStreaming: Bool,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 120,
        systemMessage: String = "You are a concise assistant.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> AgentProviderConnectionTestResult {
        let normalizedBaseURL = try validateBaseURL(baseURL)
        let validatedModel = try validateModel(model)
        let validatedAPIKey = try validateAPIKey(apiKey)
        let validatedSystemMessage = validateMessage(systemMessage)
        let validatedUserMessage = validateMessage(userMessage)

        let request = LLMRequest(
            baseURL: try validateBaseURLAsURL(baseURL),
            apiKey: validatedAPIKey,
            model: validatedModel,
            messages: [
                LLMMessage(role: "system", content: validatedSystemMessage),
                LLMMessage(role: "user", content: validatedUserMessage)
            ],
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            stream: isStreaming
        )

        let start = ContinuousClock.now
        let response: LLMResponse = try await withTimeout(seconds: timeoutSeconds) {
            if isStreaming {
                return try await readStreamingResponse(request: request)
            }
            return try await provider.complete(request: request)
        }
        let elapsed = start.duration(to: .now)
        let latencyMs = max(1, Int(elapsed.components.seconds) * 1_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))

        return AgentProviderConnectionTestResult(
            model: validatedModel,
            baseURL: normalizedBaseURL,
            isStreaming: isStreaming,
            latencyMs: latencyMs,
            outputPreview: sanitizeOutputPreview(response.text)
        )
    }

    func testConnectionWithStoredCredential(
        baseURL: String,
        apiKeyRef: String,
        model: String,
        isStreaming: Bool,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 120,
        systemMessage: String = "You are a concise assistant.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> AgentProviderConnectionTestResult {
        let ref = apiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
            throw AgentProviderValidationError.missingCredentialRef
        }
        let rawAPIKey = try credentialStore.readSecret(for: ref)
        return try await testConnection(
            baseURL: baseURL,
            apiKey: rawAPIKey,
            model: model,
            isStreaming: isStreaming,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            timeoutSeconds: timeoutSeconds,
            systemMessage: systemMessage,
            userMessage: userMessage
        )
    }

    func normalizedBaseURL(_ rawValue: String) throws -> String {
        try validateBaseURL(rawValue)
    }

    func validateModelName(_ rawValue: String) throws -> String {
        try validateModel(rawValue)
    }

    private func validateBaseURL(_ rawValue: String) throws -> String {
        try validateBaseURLAsURL(rawValue).absoluteString
    }

    private func validateBaseURLAsURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw AgentProviderValidationError.invalidBaseURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AgentProviderValidationError.unsupportedBaseURLScheme
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var normalizedPath = components?.path ?? ""
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        components?.path = normalizedPath

        guard let normalized = components?.url else {
            throw AgentProviderValidationError.invalidBaseURL
        }
        return normalized
    }

    private func validateModel(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AgentProviderValidationError.emptyModel
        }
        return value
    }

    private func validateAPIKey(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AgentProviderValidationError.emptyAPIKey
        }
        return value
    }

    private func validateMessage(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return ""
        }
        return value
    }

    private func readStreamingResponse(request: LLMRequest) async throws -> LLMResponse {
        try await provider.stream(request: request) { _ in }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clampedSeconds = max(seconds, 1)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(clampedSeconds))
                throw JobError.timeout("aiSmokeTest")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func sanitizeOutputPreview(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }
        let idx = compact.index(compact.startIndex, offsetBy: 80)
        return String(compact[..<idx]) + "…"
    }
}
