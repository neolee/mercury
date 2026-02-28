import Foundation

struct ProviderUsageReportContext: Identifiable {
    let id: Int64
    let providerName: String
    let isArchived: Bool
}

struct ModelUsageReportContext: Identifiable {
    let id: Int64
    let modelName: String
    let isArchived: Bool
}

struct AgentUsageReportContext: Identifiable {
    let taskType: AgentTaskType

    var id: String {
        taskType.rawValue
    }
}
