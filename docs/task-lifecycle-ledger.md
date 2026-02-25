# Task Lifecycle Ledger (Step 0 Baseline)

Date: 2026-02-25
Owner: Lifecycle refactor stream
Status: Baseline inventory complete; Step 1/2/3/4/5/6 landed

This ledger is the machine-checkable baseline for refactor classes `A-G` in `docs/task-lifecycle.md`.

Columns:
- `artifact`: current code artifact.
- `current_role`: what it does today.
- `target_role`: what it should do after unification.
- `class`: non-compliance class (`A-G`) or `Compliant`.
- `owner`: final owner layer (`Queue` / `Runtime` / `Orchestrator` / `Presentation` / `Persistence` / `Telemetry`).
- `status`: `as-is` | `needs-change` | `to-remove`.
- `source_ref`: current source of truth location.

## Ledger

| artifact | current_role | target_role | class | owner | status | source_ref |
|---|---|---|---|---|---|---|
| `AppTaskKind` | Queue task kind enum (includes agent + non-agent) | Projection from canonical `UnifiedTaskKind` into queue domain | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:11`; `Mercury/Mercury/TaskLifecycleCore.swift` |
| `AgentTaskKind` | Runtime task kind enum for owner/slot orchestration | Agent-only runtime projection from canonical kind | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRunCore.swift:3`; `Mercury/Mercury/TaskLifecycleCore.swift` |
| `AgentTaskType` | Persisted DB task type enum | Persistence projection from canonical kind | Compliant | Persistence | as-is | `Mercury/Mercury/Models.swift:11`; `Mercury/Mercury/TaskLifecycleCore.swift` |
| `TaskLifecycleCore` (`UnifiedTaskKind` mappings + `TaskTerminalOutcome`) | Canonical mapping and terminal semantic source module | Single allowed cross-kind mapping layer and canonical terminal type | Compliant | Orchestrator | as-is | `Mercury/Mercury/TaskLifecycleCore.swift` |
| `TaskQueue.enqueue` consumes caller-supplied task ID | Queue no longer mints task-local IDs | Consume pre-created canonical task ID | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:229` |
| `AgentTaskSpec.taskId` + app-level `makeTaskID()` request boundary | Runtime spec consumes caller ID from a single app-level constructor path | Consume canonical ID from one creation boundary | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRunCore.swift:49`; `Mercury/Mercury/AppModel.swift`; `Mercury/Mercury/Views/ReaderSummaryView.swift`; `Mercury/Mercury/Views/ReaderTranslationView.swift` |
| `SummaryRunEvent.started(UUID)` | Emits unified request task ID to UI flow | Emit canonical task ID | Compliant | Orchestrator | as-is | `Mercury/Mercury/AppModel+SummaryExecution.swift:21` |
| `TranslationRunEvent.started(UUID)` | Emits unified request task ID to UI flow | Emit canonical task ID | Compliant | Orchestrator | as-is | `Mercury/Mercury/AppModel+TranslationExecution.swift:11` |
| `AgentRuntimeEngine` no fallback `UUID()` for task events | Runtime no longer synthesizes task IDs in emits | Never synthesize IDs; require canonical ID presence | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRuntimeEngine.swift` |
| `AppTaskState` (`queued/running/succeeded/failed/timedOut/cancelled`) | Queue-visible lifecycle includes explicit timeout terminal | Keep as queue projection from canonical terminal outcome | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:114` |
| `AgentRunPhase` includes `.timedOut` | Runtime terminal phase can represent timeout | Keep as runtime projection of canonical terminal | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRunCore.swift:9` |
| `AgentTaskRunStatus` (`queued/running/succeeded/failed/timedOut/cancelled`) | Persisted run status includes timeout terminal | Keep as persistence projection from canonical terminal outcome | Compliant | Persistence | as-is | `Mercury/Mercury/Models.swift:17` |
| `LLMUsageRequestStatus` includes `.timedOut` | Telemetry can represent timeout | Keep mapped from canonical terminal outcome | Compliant | Telemetry | as-is | `Mercury/Mercury/Models.swift:31` |
| `AppTaskTerminationReason` (`userCancelled/timedOut`) | Execution-plane cancellation signal source | Keep as execution signal input only; not a terminal semantic writer | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:34` |
| `AppTaskExecutionContext` (`reportProgress` + `terminationReason`) | Explicit task execution context passed into operation closures | Canonical execution-plane signal carrier, replacing implicit task-local context | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift` |
| `TaskQueue.withExecutionTimeout` | Enforces deadline by throwing timeout error + cancellation | Keep execution deadline owner; emit canonical timeout signal | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:368` |
| `TaskQueue.start catch CancellationError/AppTaskTimeoutError` | Distinguishes timeout (`.timedOut`) and user cancel (`.cancelled`) in queue terminal state | Keep explicit timeout/cancel projection in queue catch path | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:356` |
| `resolveAgentCancellationOutcome` | Maps explicit execution-context reason to canonical timeout/cancelled terminal outcome | Keep as deterministic cancellation semantic mapper in orchestrator | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift` |
| `isCancellationLikeError` | Normalizes `CancellationError` and provider-level `.cancelled` into one semantic cancellation signal | Keep as shared cancellation normalization guard so timeout/cancel mapping always flows through execution-context reason | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift` |
| `handleAgentCancellation` timeout path via `recordAgentTerminalOutcome(... .timedOut ...)` | Timeout persisted as `status: .timedOut` | Keep timeout persistence mapped from canonical terminal outcome | Compliant | Orchestrator/Persistence | as-is | `Mercury/Mercury/AgentExecutionShared.swift:273` |
| `handleAgentCancellation` user-cancel path writes run `status: .cancelled` | User cancel persisted distinctly | Keep, mapped from canonical terminal | Compliant | Orchestrator/Persistence | as-is | `Mercury/Mercury/AgentExecutionShared.swift:177` |
| `handleAgentFailure` + `terminalOutcomeForFailure(...)` | Shared failure terminal persistence/debug projection now maps timeout-like failures to canonical `.timedOut` terminal outcome | Keep as single failure-terminal writer entrypoint with timeout-aware outcome mapping | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift` |
| `recordAgentTerminalRun` | Terminal persistence writer called via shared orchestrator path | Keep as single terminal persistence API under orchestrator-owned entrypoints | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift:385` |
| `startSummaryRun` terminal handling | Uses shared terminal writers and emits unified `.terminal(TaskTerminalOutcome)` events | Keep orchestrator as single semantic source for summary terminal events | Compliant | Orchestrator | as-is | `Mercury/Mercury/AppModel+SummaryExecution.swift` |
| `startTranslationRun` terminal handling | Uses shared terminal writers and emits unified `.terminal(TaskTerminalOutcome)` events | Keep orchestrator as single semantic source for translation terminal events | Compliant | Orchestrator | as-is | `Mercury/Mercury/AppModel+TranslationExecution.swift` |
| `ReaderSummaryView` terminal handling | Consumes unified terminal outcome and projects runtime terminal phase via mapping (`outcome.agentRunPhase`) | Keep presentation as projection-only layer with no ad hoc timeout/cancel derivation | Compliant | Presentation/Runtime | as-is | `Mercury/Mercury/Views/ReaderSummaryView.swift` |
| `ReaderTranslationView` terminal handling | Consumes unified terminal outcome and projects runtime terminal phase via mapping (`outcome.agentRunPhase`) | Keep presentation as projection-only layer with no ad hoc timeout/cancel derivation | Compliant | Presentation/Runtime | as-is | `Mercury/Mercury/Views/ReaderTranslationView.swift` |
| `AgentRuntimeEngine.finish` | Runtime terminal writer (`completed/failed/cancelled/timedOut`) | Keep runtime phase terminal writer only (not semantic source) | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRuntimeEngine.swift:100` |
| `AgentRuntimePolicy.perTaskWaitingLimit` | Runtime waiting limit policy field | Single waiting-capacity source for runtime waiting lifecycle | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRunCore.swift` |
| `AgentTaskSpec` (without queue policy override) | Per-submit runtime request envelope with identity/owner/source metadata | Spec should carry only task identity and request metadata; waiting policy belongs to runtime policy | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRunCore.swift` |
| `AgentRuntimeEngine.submit` uses `policy.waitingLimit(for:)` | Effective waiting policy decided by runtime policy | Runtime policy is authoritative for waiting-capacity enforcement | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRuntimeEngine.swift` |
| `UnifiedTaskExecutionRouter` | Canonical task-family routing adapter (`queueOnly` vs `queueAndRuntime`) | Explicit central routing authority for class-F boundary | Compliant | Orchestrator | as-is | `Mercury/Mercury/TaskLifecycleCore.swift` |
| `AppModel.submitAgentTask(...)` | Single app-level runtime submit entry for agent tasks | Centralized queue+runtime routing enforcement point for reader agent submits | Compliant | Orchestrator/Runtime | as-is | `Mercury/Mercury/AppModel+TaskLifecycle.swift` |
| Non-agent tasks (`sync/import/export/bootstrap`) through `enqueueTask` only | Queue-only execution path | Keep queue-only path for non-agent families | Compliant | Queue | as-is | `Mercury/Mercury/AppModel+Sync.swift:129,177,299`; `Mercury/Mercury/AppModel+ImportExport.swift:15,50` |
| `TaskCenter.apply` queue debug insertion | Generic failure logging now restricted to queue-only task families; agent failures/timeouts no longer double-write | Keep queue-layer debug output for non-agent tasks only | Compliant | Queue/Presentation | as-is | `Mercury/Mercury/TaskQueue.swift:530` |
| `recordAgentTerminalOutcome` debug writes | Centralized agent-specific debug projection for failure/timeout/cancel remains single writer for agent outcomes | Keep as canonical agent debug writer | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift:159` |
| `TaskTerminalOutcome.agentDebugIssueProjection(...)` | Canonical terminal-outcome -> debug projection helper (skips expected config outcomes, includes timeout/cancel/failure diagnostics; timeout includes `timeoutKind`) | Keep as single debug projection source for agent terminal outcomes | Compliant | Orchestrator | as-is | `Mercury/Mercury/TaskLifecycleCore.swift:262` |
| LLM usage cancellation mapping | Summary/translation usage cancellation status maps via shared helper (`usageStatusForCancellation`) from explicit execution-context reason | Keep as canonical cancellation-status projection for per-request usage events | Compliant | Telemetry | as-is | `Mercury/Mercury/AgentExecutionShared.swift`; `Mercury/Mercury/AppModel+SummaryExecution.swift`; `Mercury/Mercury/AppModel+TranslationExecution.swift` |
| `usageStatusForFailure(error:taskKind:)` | Canonical non-cancellation error -> usage status projection (timeout-like provider errors map to `.timedOut`) | Keep as single usage-failure projection source | Compliant | Telemetry | as-is | `Mercury/Mercury/AgentExecutionShared.swift:129` |
| `LLMProviderError.timedOut(kind:message:)` | Provider layer now emits explicit timeout semantic error (request/resource/stream-first-token/stream-idle) instead of relying only on free-text messages | Keep as canonical provider-timeout contract consumed by classifier/projection layers | Compliant | Runtime/Provider | as-is | `Mercury/Mercury/AgentFoundation.swift` |
| `AgentFailureClassifier` provider-network timeout normalization | `LLMProviderError.network(message)` now maps timeout-like messages to `AgentFailureReason.timedOut` (request/resource/first-token/idle) | Keep as timeout semantic normalization gate before terminal projection | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentFailureClassifier.swift` |
| `AgentLLMProvider` URLSession timeout transport mapping | `LLMNetworkTimeoutProfile.request/resource` now projects into transport-level `URLSessionConfiguration` (`timeoutIntervalForRequest/resource`) via `HTTPClient` injection, so provider/network timeout semantics are enforced below orchestration | Keep provider transport as the single network request/resource timeout owner; runtime/orchestrator consume normalized timeout errors only | Compliant | Runtime/Provider | as-is | `Mercury/Mercury/AgentLLMProvider.swift` |
| `AgentRuntimeProjection.bannerMessage(for:taskKind:)` | Reader banner projection now derives message directly from canonical `TaskTerminalOutcome` | Keep as single banner projection entry for terminal outcome display | Compliant | Presentation | as-is | `Mercury/Mercury/AgentRuntimeProjection.swift:244` |
| Step 5 projection tests (`TaskTerminationSemanticsTests`, `AgentFailureMessageProjectionTests`) | Verifies timeout usage/debug/banner projections are consistent with canonical terminal outcomes | Keep as regression guard for class-G convergence | Compliant | Test | as-is | `Mercury/MercuryTest/TaskTerminationSemanticsTests.swift`; `Mercury/MercuryTest/AgentFailureMessageProjectionTests.swift` |
| Step 3 semantic tests (`TaskTerminationSemanticsTests`) | Verifies timeout vs cancel mapping and execution-context reason propagation in queue cancellation paths | Keep as regression guard for terminal semantic determinism | Compliant | Test | as-is | `Mercury/MercuryTest/TaskTerminationSemanticsTests.swift` |
| Step 6 hardening tests (`AgentFailureClassifierTests`, `TaskQueueQueueOnlyTerminationTests`, `TaskTimeoutPolicyTests`, `AgentLLMProviderTimeoutTransportTests`) | Verifies timeout-source normalization, queue-only timeout/cancel/failure matrix, timeout policy defaults/projections, and provider transport timeout mapping | Keep as regression gate for integration-level lifecycle hardening | Compliant | Test | as-is | `Mercury/MercuryTest/AgentFailureClassifierTests.swift`; `Mercury/MercuryTest/TaskQueueQueueOnlyTerminationTests.swift`; `Mercury/MercuryTest/TaskTimeoutPolicyTests.swift`; `Mercury/MercuryTest/AgentLLMProviderTimeoutTransportTests.swift` |

## Immediate Findings Summary

1. Step 3 semantic convergence is landed: canonical terminal event, projection-only UI mapping, and explicit cancellation reason flow.
2. Step 4 scheduling/routing convergence is landed: single runtime waiting-capacity source and centralized task-family routing adapter.
3. Step 5+6 convergence is landed: canonical observability projections + hardening test matrix and timeout-source normalization.

## Baseline Acceptance Checklist

- [x] Queue task lifecycle artifacts listed.
- [x] Runtime lifecycle artifacts listed.
- [x] Persistence/telemetry status artifacts listed.
- [x] Agent orchestration terminal-write paths listed.
- [x] Reader projection terminal mapping paths listed.
- [x] Non-agent queue-only path explicitly classified.
- [x] Canonical mapping table implemented in code.
- [x] Single terminal writer enforcement implemented in code.
