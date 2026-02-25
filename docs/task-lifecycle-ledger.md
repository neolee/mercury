# Task Lifecycle Ledger (Step 0 Baseline)

Date: 2026-02-25
Owner: Lifecycle refactor stream
Status: Baseline inventory complete; Step 1/2/3 landed

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
| `handleAgentFailure` shared failed-terminal path | Shared failure terminal persistence/debug projection for summary+translation | Keep as single failed-terminal writer entrypoint; later merge with cancellation terminal mapping | D | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift` |
| `recordAgentTerminalRun` | Terminal persistence writer called via shared orchestrator path | Keep as single terminal persistence API under orchestrator-owned entrypoints | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift:385` |
| `startSummaryRun` terminal handling | Uses shared terminal writers and emits unified `.terminal(TaskTerminalOutcome)` events | Keep orchestrator as single semantic source for summary terminal events | Compliant | Orchestrator | as-is | `Mercury/Mercury/AppModel+SummaryExecution.swift` |
| `startTranslationRun` terminal handling | Uses shared terminal writers and emits unified `.terminal(TaskTerminalOutcome)` events | Keep orchestrator as single semantic source for translation terminal events | Compliant | Orchestrator | as-is | `Mercury/Mercury/AppModel+TranslationExecution.swift` |
| `ReaderSummaryView` terminal handling | Consumes unified terminal outcome and projects runtime terminal phase via mapping (`outcome.agentRunPhase`) | Keep presentation as projection-only layer with no ad hoc timeout/cancel derivation | Compliant | Presentation/Runtime | as-is | `Mercury/Mercury/Views/ReaderSummaryView.swift` |
| `ReaderTranslationView` terminal handling | Consumes unified terminal outcome and projects runtime terminal phase via mapping (`outcome.agentRunPhase`) | Keep presentation as projection-only layer with no ad hoc timeout/cancel derivation | Compliant | Presentation/Runtime | as-is | `Mercury/Mercury/Views/ReaderTranslationView.swift` |
| `AgentRuntimeEngine.finish` | Runtime terminal writer (`completed/failed/cancelled/timedOut`) | Keep runtime phase terminal writer only (not semantic source) | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRuntimeEngine.swift:100` |
| `AgentRuntimePolicy.perTaskWaitingLimit` | Runtime waiting limit policy field | Single waiting-capacity source; remove duplicate policy path | E | Runtime | needs-change | `Mercury/Mercury/AgentRunCore.swift:126` |
| `AgentTaskSpec.queuePolicy.waitingCapacityPerKind` | Per-submit waiting capacity override | Avoid semantic overlap with runtime policy; define one source | E | Runtime | needs-change | `Mercury/Mercury/AgentRunCore.swift:40` |
| `AgentRuntimeEngine.submit` uses `spec.queuePolicy.waitingCapacityPerKind` | Effective waiting policy decided by spec, not runtime policy | Runtime policy should be authoritative for waiting capacity | E | Runtime | needs-change | `Mercury/Mercury/AgentRuntimeEngine.swift:44` |
| `AgentRuntimeContract.baselineWaitingCapacityPerKind` | Another waiting-limit knob used in views | Replace with centralized runtime waiting policy | E | Runtime | to-remove | `Mercury/Mercury/AgentRunCore.swift:119` |
| Non-agent tasks (`sync/import/export/bootstrap`) through `enqueueTask` only | Queue-only execution path | Keep queue-only path for non-agent families | Compliant | Queue | as-is | `Mercury/Mercury/AppModel+Sync.swift:129,177,299`; `Mercury/Mercury/AppModel+ImportExport.swift:15,50` |
| `TaskCenter.apply` queue debug insertion | Generic failure logging now restricted to queue-only task families; agent failures/timeouts no longer double-write | Keep queue-layer debug output for non-agent tasks only | Compliant | Queue/Presentation | as-is | `Mercury/Mercury/TaskQueue.swift:530` |
| `recordAgentTerminalOutcome` debug writes | Centralized agent-specific debug projection for failure/timeout/cancel remains single writer for agent outcomes | Keep as canonical agent debug writer | Compliant | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift:159` |
| LLM usage cancellation mapping | Summary/translation usage cancellation status maps via shared helper (`usageStatusForCancellation`) from explicit execution-context reason | Keep as canonical cancellation-status projection for per-request usage events | Compliant | Telemetry | as-is | `Mercury/Mercury/AgentExecutionShared.swift`; `Mercury/Mercury/AppModel+SummaryExecution.swift`; `Mercury/Mercury/AppModel+TranslationExecution.swift` |
| Step 3 semantic tests (`TaskTerminationSemanticsTests`) | Verifies timeout vs cancel mapping and execution-context reason propagation in queue cancellation paths | Keep as regression guard for terminal semantic determinism | Compliant | Test | as-is | `Mercury/MercuryTest/TaskTerminationSemanticsTests.swift` |

## Immediate Findings Summary

1. Step 3 semantic convergence is landed: canonical terminal event, projection-only UI mapping, and explicit cancellation reason flow.
2. Waiting-capacity policy still has overlapping knobs (`policy`, `spec.queuePolicy`, `baseline constant`).
3. Routing authority between queue-only tasks and agent-runtime tasks is not yet centralized.

## Baseline Acceptance Checklist

- [x] Queue task lifecycle artifacts listed.
- [x] Runtime lifecycle artifacts listed.
- [x] Persistence/telemetry status artifacts listed.
- [x] Agent orchestration terminal-write paths listed.
- [x] Reader projection terminal mapping paths listed.
- [x] Non-agent queue-only path explicitly classified.
- [x] Canonical mapping table implemented in code.
- [x] Single terminal writer enforcement implemented in code.
