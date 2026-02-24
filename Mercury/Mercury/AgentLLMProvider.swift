//
//  AgentLLMProvider.swift
//  Mercury
//
//  Created by GitHub Copilot on 2026/2/18.
//

import Foundation
import SwiftOpenAI

struct AgentLLMProvider: LLMProvider {
    let providerName: String = "SwiftOpenAI"

    private struct ServiceRoutePlan {
        let overrideBaseURL: String
        let proxyPath: String?
        let version: String?
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        let primaryPlan = serviceRoutePlan(from: request.baseURL)

        do {
            return try await performComplete(request: request, routePlan: primaryPlan)
        } catch let primaryError {
            if let fallbackPlan = fallbackRoutePlanRemovingVersionIfNeeded(primaryPlan: primaryPlan, error: primaryError) {
                do {
                    return try await performComplete(request: request, routePlan: fallbackPlan)
                } catch let fallbackError {
                    throw mapError(
                        fallbackError,
                        baseURL: request.baseURL,
                        primaryPlan: primaryPlan,
                        fallbackPlanTried: fallbackPlan
                    )
                }
            }

            throw mapError(
                primaryError,
                baseURL: request.baseURL,
                primaryPlan: primaryPlan,
                fallbackPlanTried: nil
            )
        }
    }

    func stream(
        request: LLMRequest,
        onEvent: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> LLMResponse {
        let primaryPlan = serviceRoutePlan(from: request.baseURL)

        do {
            return try await performStream(
                request: request,
                routePlan: primaryPlan,
                onEvent: onEvent
            )
        } catch let primaryError {
            if let fallbackPlan = fallbackRoutePlanRemovingVersionIfNeeded(primaryPlan: primaryPlan, error: primaryError) {
                do {
                    return try await performStream(
                        request: request,
                        routePlan: fallbackPlan,
                        onEvent: onEvent
                    )
                } catch let fallbackError {
                    throw mapError(
                        fallbackError,
                        baseURL: request.baseURL,
                        primaryPlan: primaryPlan,
                        fallbackPlanTried: fallbackPlan
                    )
                }
            }

            throw mapError(
                primaryError,
                baseURL: request.baseURL,
                primaryPlan: primaryPlan,
                fallbackPlanTried: nil
            )
        }
    }

    private func performComplete(
        request: LLMRequest,
        routePlan: ServiceRoutePlan
    ) async throws -> LLMResponse {
        let service = makeService(routePlan: routePlan, apiKey: request.apiKey)
        let parameters = makeChatParameters(request: request, includeStreamUsage: false)
        let response = try await service.startChat(parameters: parameters)
        let text = response.choices?.first?.message?.content ?? ""
        return LLMResponse(
            text: text,
            usagePromptTokens: response.usage?.promptTokens,
            usageCompletionTokens: response.usage?.completionTokens,
            resolvedEndpoint: makeResolvedEndpointSnapshot(from: routePlan)
        )
    }

    private func performStream(
        request: LLMRequest,
        routePlan: ServiceRoutePlan,
        onEvent: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> LLMResponse {
        let service = makeService(routePlan: routePlan, apiKey: request.apiKey)
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
            usageCompletionTokens: usageCompletionTokens,
            resolvedEndpoint: makeResolvedEndpointSnapshot(from: routePlan)
        )
    }

    private func makeResolvedEndpointSnapshot(from routePlan: ServiceRoutePlan) -> LLMResolvedEndpoint? {
        guard let endpoint = URL(string: inferredChatEndpoint(from: routePlan)) else {
            return nil
        }
        let host = endpoint.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = endpoint.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMResolvedEndpoint(
            url: endpoint.absoluteString,
            host: host?.isEmpty == false ? host : nil,
            path: path.isEmpty == false ? path : nil
        )
    }

    private func makeService(routePlan: ServiceRoutePlan, apiKey: String) -> OpenAIService {
        OpenAIServiceFactory.service(
            apiKey: apiKey,
            overrideBaseURL: routePlan.overrideBaseURL,
            proxyPath: routePlan.proxyPath,
            overrideVersion: routePlan.version,
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

    private func mapError(
        _ error: Error,
        baseURL: URL,
        primaryPlan: ServiceRoutePlan,
        fallbackPlanTried: ServiceRoutePlan?
    ) -> LLMProviderError {
        if error is CancellationError {
            return .cancelled
        }

        if let apiError = error as? APIError {
            switch apiError {
            case .responseUnsuccessful(let description, let statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return .unauthorized
                }
                if statusCode == 404 {
                    let primaryEndpoint = inferredChatEndpoint(from: primaryPlan)
                    let retryDetails: String
                    if let fallbackPlanTried {
                        let fallbackEndpoint = inferredChatEndpoint(from: fallbackPlanTried)
                        retryDetails = " Retried with resolved endpoint \(fallbackEndpoint)."
                    } else {
                        retryDetails = ""
                    }
                    return .network(
                        "HTTP 404: endpoint not found. Current base URL is \(baseURL.absoluteString). " +
                        "SwiftOpenAI resolved endpoint is \(primaryEndpoint)." +
                        retryDetails +
                        " Expected OpenAI-compatible chat endpoint is usually '<baseURL>/chat/completions'. " +
                        "For DashScope, base URL should be 'https://dashscope.aliyuncs.com/compatible-mode/v1'."
                    )
                }
                let details = description.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty == false {
                    return .network("HTTP \(statusCode): \(details)")
                }
                return .network("HTTP \(statusCode): \(apiError.displayDescription)")
            case .requestFailed(let description):
                let details = description.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty == false {
                    return .network(details)
                }
                return .network(apiError.displayDescription)
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

    private func inferredChatEndpoint(from routePlan: ServiceRoutePlan) -> String {
        guard var components = URLComponents(string: routePlan.overrideBaseURL) else {
            return "<invalid endpoint>"
        }

        var segments: [String] = []
        if let proxyPath = routePlan.proxyPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           proxyPath.isEmpty == false {
            segments.append(proxyPath)
        }
        if let version = routePlan.version, version.isEmpty == false {
            segments.append(version)
        }
        segments.append("chat")
        segments.append("completions")

        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "<invalid endpoint>"
    }

    private func serviceRoutePlan(from baseURL: URL) -> ServiceRoutePlan {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let rawPath = components?.path ?? ""
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var pathSegments = trimmedPath.isEmpty ? [] : trimmedPath.split(separator: "/").map(String.init)
        var version: String? = "v1"
        if let lastSegment = pathSegments.last, isVersionSegment(lastSegment) {
            version = lastSegment
            pathSegments.removeLast()
        }

        let proxyPath = pathSegments.isEmpty ? nil : pathSegments.joined(separator: "/")

        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        let overrideBaseURL = components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return ServiceRoutePlan(
            overrideBaseURL: overrideBaseURL,
            proxyPath: proxyPath,
            version: version
        )
    }

    private func fallbackRoutePlanRemovingVersionIfNeeded(
        primaryPlan: ServiceRoutePlan,
        error: Error
    ) -> ServiceRoutePlan? {
        guard isHTTP404(error) else {
            return nil
        }

        guard (primaryPlan.version ?? "").lowercased() == "v1" else {
            return nil
        }

        return ServiceRoutePlan(
            overrideBaseURL: primaryPlan.overrideBaseURL,
            proxyPath: primaryPlan.proxyPath,
            version: ""
        )
    }

    private func isHTTP404(_ error: Error) -> Bool {
        guard case .responseUnsuccessful(_, let statusCode) = (error as? APIError) else {
            return false
        }
        return statusCode == 404
    }

    private func isVersionSegment(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard lowercased.hasPrefix("v") else {
            return false
        }
        let suffix = lowercased.dropFirst()
        return suffix.isEmpty == false && suffix.allSatisfy(\.isNumber)
    }
}
