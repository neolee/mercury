//
//  AppModel+AI.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation

extension AppModel {
    func normalizeAIBaseURL(_ baseURL: String) throws -> String {
        try aiProviderValidationUseCase.normalizedBaseURL(baseURL)
    }

    func validateAIModelName(_ model: String) throws -> String {
        try aiProviderValidationUseCase.validateModelName(model)
    }

    func saveAIProviderAPIKey(_ apiKey: String, ref: String) throws {
        try credentialStore.save(secret: apiKey, for: ref)
    }

    func deleteAIProviderAPIKey(ref: String) throws {
        try credentialStore.deleteSecret(for: ref)
    }

    func testAIProviderConnection(
        baseURL: String,
        apiKey: String,
        model: String,
        isStreaming: Bool = false
    ) async throws -> AIProviderConnectionTestResult {
        try await aiProviderValidationUseCase.testConnection(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            isStreaming: isStreaming
        )
    }

    func testAIProviderConnection(
        baseURL: String,
        apiKeyRef: String,
        model: String,
        isStreaming: Bool = false
    ) async throws -> AIProviderConnectionTestResult {
        try await aiProviderValidationUseCase.testConnectionWithStoredCredential(
            baseURL: baseURL,
            apiKeyRef: apiKeyRef,
            model: model,
            isStreaming: isStreaming
        )
    }
}
