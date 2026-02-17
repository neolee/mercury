//
//  AIProviderValidation.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation

struct AIProviderValidationUseCase {
    let provider: any LLMProvider
    let credentialStore: CredentialStore

    func testConnection(
        baseURL: String,
        apiKey: String,
        model: String,
        isStreaming: Bool
    ) async throws -> AIProviderConnectionTestResult {
        let normalizedBaseURL = try validateBaseURL(baseURL)
        let validatedModel = try validateModel(model)
        let validatedAPIKey = try validateAPIKey(apiKey)

        let request = LLMRequest(
            baseURL: try validateBaseURLAsURL(baseURL),
            apiKey: validatedAPIKey,
            model: validatedModel,
            messages: [
                LLMMessage(role: "system", content: "You are a concise assistant."),
                LLMMessage(role: "user", content: "Reply with exactly: ok")
            ],
            temperature: 0,
            topP: nil,
            maxTokens: 16,
            stream: isStreaming
        )

        let start = ContinuousClock.now
        let response: LLMResponse
        if isStreaming {
            response = try await readStreamingResponse(request: request)
        } else {
            response = try await provider.complete(request: request)
        }
        let elapsed = start.duration(to: .now)
        let latencyMs = max(1, Int(elapsed.components.seconds) * 1_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))

        return AIProviderConnectionTestResult(
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
        isStreaming: Bool
    ) async throws -> AIProviderConnectionTestResult {
        let ref = apiKeyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
            throw AIProviderValidationError.missingCredentialRef
        }
        let rawAPIKey = try credentialStore.readSecret(for: ref)
        return try await testConnection(
            baseURL: baseURL,
            apiKey: rawAPIKey,
            model: model,
            isStreaming: isStreaming
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
            throw AIProviderValidationError.invalidBaseURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AIProviderValidationError.unsupportedBaseURLScheme
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var normalizedPath = components?.path ?? ""
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        if normalizedPath == "/v1" {
            normalizedPath = ""
        }
        components?.path = normalizedPath

        guard let normalized = components?.url else {
            throw AIProviderValidationError.invalidBaseURL
        }
        return normalized
    }

    private func validateModel(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AIProviderValidationError.emptyModel
        }
        return value
    }

    private func validateAPIKey(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AIProviderValidationError.emptyAPIKey
        }
        return value
    }

    private func readStreamingResponse(request: LLMRequest) async throws -> LLMResponse {
        try await provider.stream(request: request) { _ in }
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
