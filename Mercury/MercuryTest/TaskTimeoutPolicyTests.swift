import Testing
@testable import Mercury

@Suite("Task Timeout Policy")
struct TaskTimeoutPolicyTests {
    @Test("Execution timeout defaults freeze by task kind")
    func executionTimeoutDefaults() {
        #expect(TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.summary) == 180)
        #expect(TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.translation) == 300)
        #expect(TaskTimeoutPolicy.executionTimeout(for: AppTaskKind.syncFeeds) == nil)
    }

    @Test("Network timeout defaults freeze")
    func networkTimeoutDefaults() {
        let network = TaskTimeoutPolicy.defaultNetwork
        #expect(network.requestTimeout == 120)
        #expect(network.resourceTimeout == 600)
        #expect(network.streamFirstTokenTimeout == 120)
        #expect(network.streamIdleTimeout == 60)
    }

    @Test("LLM timeout profile projection preserves network policy values")
    func llmTimeoutProfileProjection() {
        let profile = LLMNetworkTimeoutProfile(policy: TaskTimeoutPolicy.defaultNetwork)
        #expect(profile.requestTimeoutSeconds == 120)
        #expect(profile.resourceTimeoutSeconds == 600)
        #expect(profile.streamFirstTokenTimeoutSeconds == 120)
        #expect(profile.streamIdleTimeoutSeconds == 60)
    }
}
