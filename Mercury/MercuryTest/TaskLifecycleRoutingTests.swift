import Foundation
import Testing
@testable import Mercury

@Suite("Task Lifecycle Routing")
struct TaskLifecycleRoutingTests {
    @Test("Agent kinds route through queue and runtime planes")
    func agentKindsRouteThroughQueueAndRuntime() {
        #expect(
            UnifiedTaskExecutionRouter.route(for: .summary)
                == .queueAndRuntime(appTaskKind: .summary, agentTaskKind: .summary)
        )
        #expect(
            UnifiedTaskExecutionRouter.route(for: .translation)
                == .queueAndRuntime(appTaskKind: .translation, agentTaskKind: .translation)
        )
        #expect(
            UnifiedTaskExecutionRouter.route(for: .tagging)
                == .queueAndRuntime(appTaskKind: .custom, agentTaskKind: .tagging)
        )
    }

    @Test("Queue-only kinds never route to runtime plane")
    func queueOnlyKindsDoNotRouteToRuntime() {
        #expect(UnifiedTaskExecutionRouter.route(for: .syncFeeds) == .queueOnly(appTaskKind: .syncFeeds))
        #expect(UnifiedTaskExecutionRouter.route(for: .importOPML) == .queueOnly(appTaskKind: .importOPML))
        #expect(UnifiedTaskExecutionRouter.route(for: .custom) == .queueOnly(appTaskKind: .custom))
    }
}
