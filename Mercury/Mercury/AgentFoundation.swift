import Foundation
import Security

enum AgentStreamEvent: Sendable {
    case token(String)
    case completed
}

struct LLMMessage: Sendable {
    let role: String
    let content: String
}

struct LLMRequest: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
    let messages: [LLMMessage]
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let stream: Bool
}

struct LLMResponse: Sendable {
    let text: String
    let usagePromptTokens: Int?
    let usageCompletionTokens: Int?
}

struct AgentProviderConnectionTestResult: Sendable {
    let model: String
    let baseURL: String
    let isStreaming: Bool
    let latencyMs: Int
    let outputPreview: String
}

enum LLMProviderError: LocalizedError {
    case invalidConfiguration(String)
    case network(String)
    case unauthorized
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid provider configuration: \(message)"
        case .network(let message):
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Provider request failed due to a network or server error."
            }
            return message
        case .unauthorized:
            return "Authentication failed. Please check API key and endpoint permission."
        case .cancelled:
            return "The request was cancelled."
        case .unknown(let message):
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Provider request failed with an unknown error."
            }
            return message
        }
    }
}

enum AgentProviderValidationError: LocalizedError {
    case invalidBaseURL
    case unsupportedBaseURLScheme
    case emptyModel
    case emptyAPIKey
    case missingCredentialRef

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Please enter a valid Base URL."
        case .unsupportedBaseURLScheme:
            return "Only http:// or https:// Base URL is supported."
        case .emptyModel:
            return "Model name cannot be empty."
        case .emptyAPIKey:
            return "API key cannot be empty."
        case .missingCredentialRef:
            return "API key reference is missing."
        }
    }
}

protocol LLMProvider: Sendable {
    var providerName: String { get }

    func complete(request: LLMRequest) async throws -> LLMResponse

    func stream(
        request: LLMRequest,
        onEvent: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> LLMResponse
}

struct AgentRunInput: Sendable {
    let taskType: AgentTaskType
    let entryId: Int64
    let sourceText: String
    let targetLanguage: String?
}

struct AgentRunResult: Sendable {
    let outputText: String
    let providerProfileId: Int64
    let modelProfileId: Int64
}

protocol AgentOrchestrator: Sendable {
    func run(
        agentProfileId: Int64,
        input: AgentRunInput,
        onEvent: @escaping @Sendable (AgentStreamEvent) async -> Void
    ) async throws -> AgentRunResult
}

enum CredentialStoreError: Error {
    case invalidSecret
    case itemNotFound
    case osStatus(OSStatus)
}

protocol CredentialStore: Sendable {
    func save(secret: String, for ref: String) throws
    func readSecret(for ref: String) throws -> String
    func deleteSecret(for ref: String) throws
}

struct KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = "Mercury.Credentials") {
        self.service = service
    }

    func save(secret: String, for ref: String) throws {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSecret.isEmpty == false else {
            throw CredentialStoreError.invalidSecret
        }

        let secretData = Data(trimmedSecret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: secretData
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = secretData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.osStatus(addStatus)
            }
        default:
            throw CredentialStoreError.osStatus(updateStatus)
        }
    }

    func readSecret(for ref: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CredentialStoreError.itemNotFound
            }
            throw CredentialStoreError.osStatus(status)
        }

        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8),
              secret.isEmpty == false else {
            throw CredentialStoreError.invalidSecret
        }

        return secret
    }

    func deleteSecret(for ref: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw CredentialStoreError.osStatus(status)
    }
}
