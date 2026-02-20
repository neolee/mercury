import Testing
@testable import Mercury

@Suite("Agent Run State Machine")
struct AgentRunStateMachineTests {
    @Test("Allows expected forward transitions for running phases")
    func allowsForwardTransitions() {
        #expect(AgentRunStateMachine.canTransition(from: .idle, to: .requesting))
        #expect(AgentRunStateMachine.canTransition(from: .idle, to: .waiting))
        #expect(AgentRunStateMachine.canTransition(from: .waiting, to: .requesting))
        #expect(AgentRunStateMachine.canTransition(from: .requesting, to: .generating))
        #expect(AgentRunStateMachine.canTransition(from: .generating, to: .persisting))
        #expect(AgentRunStateMachine.canTransition(from: .persisting, to: .completed))
    }

    @Test("Rejects backward and terminal-exit transitions")
    func rejectsInvalidTransitions() {
        #expect(AgentRunStateMachine.canTransition(from: .generating, to: .requesting) == false)
        #expect(AgentRunStateMachine.canTransition(from: .persisting, to: .generating) == false)
        #expect(AgentRunStateMachine.canTransition(from: .completed, to: .requesting) == false)
        #expect(AgentRunStateMachine.canTransition(from: .failed, to: .generating) == false)
    }

    @Test("Marks terminal phases correctly")
    func terminalPhases() {
        #expect(AgentRunStateMachine.isTerminal(.completed))
        #expect(AgentRunStateMachine.isTerminal(.failed))
        #expect(AgentRunStateMachine.isTerminal(.cancelled))
        #expect(AgentRunStateMachine.isTerminal(.timedOut))
        #expect(AgentRunStateMachine.isTerminal(.requesting) == false)
    }
}
