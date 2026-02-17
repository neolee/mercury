//
//  SwiftOpenAILLMProvider.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation
import SwiftOpenAI

struct SwiftOpenAILLMProvider: LLMProvider {
    let providerName: String = "SwiftOpenAI"

    func complete(
        request: LLMRequest
    ) async throws -> LLMResponse {
        do {
            let service = makeService(baseURL: request.baseURL.absoluteString, apiKey: request.apiKey)
            let parameters = makeChatParameters(request: request, includeStreamUsage: false)
            let response = try await service.startChat(parameters: parameters)
            let text = response.choices?.first?.message?.content ?? ""
            return LLMResponse(
                text: text,
                usagePromptTokens: response.usage?.promptTokens,
                usageCompletionTokens: response.usage?.completionTokens
            )
        } catch {
            throw mapError(error)
        }
    }

    func stream(
        request: LLMRequest,
        onEvent: @escaping @Sendable (AIStreamEvent) async -> Void
    ) async throws -> LLMResponse {
        do {
            let service = makeService(baseURL: request.baseURL.absoluteString, apiKey: request.apiKey)
            let parameters = makeChatParameters(request: request, includeStreamUsage: true)

            let chunks = try await service.startStreamedChat(parameters: parameters)
            var fullText = ""
            var usagePromptTokens: Int?
            var usageCompletionTokens: Int?

            for try await chunk in chunks {
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    fullText += delta
                    await onEvent(.token(delta))
                }
                if let usage = chunk.usage {
                    usagePromptTokens = usage.promptTokens
                    usageCompletionTokens = usage.completionTokens
                }
            }

            await onEvent(.completed)
            return LLMResponse(
                text: fullText,
                usagePromptTokens: usagePromptTokens,
                usageCompletionTokens: usageCompletionTokens
            )
        } catch {
            throw mapError(error)
        }
    }

    private func makeService(baseURL: String, apiKey: String) -> OpenAIService {
        OpenAIServiceFactory.service(
            apiKey: .bearer(apiKey),
            baseURL: baseURL,
            debugEnabled: false
        )
    }

    private func makeChatParameters(
        request: LLMRequest,
        includeStreamUsage: Bool
    ) -> ChatCompletionParameters {
        ChatCompletionParameters(
            messages: request.messages.map(makeMessage),
            model: .custom(request.model),
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topProbability: request.topP,
            streamOptions: includeStreamUsage ? .init(includeUsage: true) : nil
        )
    }

    private func makeMessage(_ message: LLMMessage) -> ChatCompletionParameters.Message {
        ChatCompletionParameters.Message(
            role: mapRole(message.role),
            content: .text(message.content)
        )
    }

    private func mapRole(_ role: String) -> ChatCompletionParameters.Message.Role {
        switch role {
        case "system":
            return .system
        case "assistant":
            return .assistant
        case "tool":
            return .tool
        case "user":
            return .user
        default:
            return .user
        }
    }

    private func mapError(_ error: Error) -> LLMProviderError {
        if error is CancellationError {
            return .cancelled
        }

        if let apiError = error as? APIError {
            switch apiError {
            case .responseUnsuccessful(let description, let statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return .unauthorized
                }
                return .network(description)
            case .requestFailed(let description):
                return .network(description)
            case .timeOutError:
                return .network("Request timed out.")
            case .jsonDecodingFailure(let description):
                return .unknown(description)
            case .dataCouldNotBeReadMissingData(let description):
                return .unknown(description)
            case .invalidData, .bothDecodingStrategiesFailed:
                return .unknown(apiError.displayDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }
}
