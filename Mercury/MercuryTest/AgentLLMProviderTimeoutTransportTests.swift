import Foundation
import Testing
@testable import Mercury

@Suite("Agent LLM Provider Timeout Transport")
struct AgentLLMProviderTimeoutTransportTests {
    @Test("URLSession timeout config is absent when profile is nil")
    func noTimeoutProfileConfig() {
        let configuration = AgentLLMProvider.makeURLSessionConfiguration(timeoutProfile: nil)
        #expect(configuration == nil)
    }

    @Test("URLSession timeout config maps request/resource timeout values")
    func timeoutProfileConfigMapping() {
        let profile = LLMNetworkTimeoutProfile(
            requestTimeoutSeconds: 123,
            resourceTimeoutSeconds: 456,
            streamFirstTokenTimeoutSeconds: 30,
            streamIdleTimeoutSeconds: 60
        )

        let configuration = AgentLLMProvider.makeURLSessionConfiguration(timeoutProfile: profile)
        #expect(configuration != nil)
        #expect(configuration?.timeoutIntervalForRequest == 123)
        #expect(configuration?.timeoutIntervalForResource == 456)
    }
}
