import Foundation
import GRDB

nonisolated enum AgentFailureReason: String, Sendable {
    case cancelled
    case timedOut = "timed_out"
    case invalidInput = "invalid_input"
    case noModelRoute = "no_model_route"
    case invalidConfiguration = "invalid_configuration"
    case authentication
    case network
    case parser
    case storage
    case unknown
}

nonisolated enum AgentFailureClassifier {
    static func classify(error: Error, taskKind: AgentTaskKind) -> AgentFailureReason {
        if error is CancellationError {
            return .cancelled
        }

        if let providerError = error as? LLMProviderError {
            switch providerError {
            case .invalidConfiguration:
                return .invalidConfiguration
            case .unauthorized:
                return .authentication
            case .timedOut:
                return .timedOut
            case .network(let message):
                if isTimeoutMessage(message) {
                    return .timedOut
                }
                return .network
            case .cancelled:
                return .cancelled
            case .unknown(let message):
                if isTimeoutMessage(message) {
                    return .timedOut
                }
                return .unknown
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return .network
            default:
                break
            }
        }

        if let credentialError = error as? CredentialStoreError {
            switch credentialError {
            case .itemNotFound:
                return .authentication
            case .invalidSecret, .osStatus:
                return .invalidConfiguration
            }
        }

        if error is DatabaseError {
            return .storage
        }
        if error is SummaryStorageError || error is TranslationStorageError {
            return .storage
        }
        if error is AppTaskTimeoutError {
            return .timedOut
        }

        if let summaryError = error as? SummaryExecutionError {
            switch summaryError {
            case .sourceTextRequired, .targetLanguageRequired:
                return .invalidInput
            case .noUsableModelRoute:
                return .noModelRoute
            }
        }

        if let translationError = error as? TranslationExecutionError {
            switch translationError {
            case .sourceSegmentsRequired, .targetLanguageRequired:
                return .invalidInput
            case .noUsableModelRoute:
                return .noModelRoute
            case .invalidBaseURL:
                return .invalidConfiguration
            case .executionTimedOut:
                return .timedOut
            case .invalidModelResponse, .missingTranslatedSegment, .emptyTranslatedSegment, .duplicateTranslatedSegment:
                return .parser
            }
        }

        let nsError = error as NSError
        if isTimeoutError(nsError) {
            return .timedOut
        }

        switch taskKind {
        case .summary, .translation, .tagging:
            return .unknown
        }
    }

    private static func isTimeoutError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == URLError.timedOut.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT) {
            return true
        }
        return isTimeoutMessage(error.localizedDescription)
    }

    private static func isTimeoutMessage(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("timed out") || message.contains("timeout")
    }
}
