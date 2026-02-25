# Task Lifecycle Ledger (Step 0 Baseline)

Date: 2026-02-25
Owner: Lifecycle refactor stream
Status: Baseline inventory complete; Step 1/2 implementation landed

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
| `AppTaskTerminationReason` (`userCancelled/timedOut`) | Side channel reason attached to cancellation flow | Input signal only; not terminal outcome source | D | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:34` |
| `AppTaskCancellationContext` task-local reason provider | Lets downstream infer cancel reason | Keep as low-level cancellation context only | D | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:39` |
| `TaskQueue.withExecutionTimeout` | Enforces deadline by throwing timeout error + cancellation | Keep execution deadline owner; emit canonical timeout signal | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:368` |
| `TaskQueue.start catch CancellationError/AppTaskTimeoutError` | Distinguishes timeout (`.timedOut`) and user cancel (`.cancelled`) in queue terminal state | Keep explicit timeout/cancel projection in queue catch path | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:356` |
| `resolveAgentCancellationOutcome` | Re-infers timeout/user-cancel from task-local reason (nil=>timeout) | Remove inference; consume explicit canonical terminal signal | D | Orchestrator | needs-change | `Mercury/Mercury/AgentExecutionShared.swift:73` |
| `handleAgentCancellation` timeout path via `recordAgentTerminalOutcome(... .timedOut ...)` | Timeout persisted as `status: .timedOut` | Keep timeout persistence mapped from canonical terminal outcome | Compliant | Orchestrator/Persistence | as-is | `Mercury/Mercury/AgentExecutionShared.swift:273` |
| `handleAgentCancellation` user-cancel path writes run `status: .cancelled` | User cancel persisted distinctly | Keep, mapped from canonical terminal | Compliant | Orchestrator/Persistence | as-is | `Mercury/Mercury/AgentExecutionShared.swift:177` |
| `handleAgentFailure` shared failed-terminal path | Shared failure terminal persistence/debug projection for summary+translation | Keep as single failed-terminal writer entrypoint; later merge with cancellation terminal mapping | D | Orchestrator | as-is | `Mercury/Mercury/AgentExecutionShared.swift` |
| `recordAgentTerminalRun` | Writes terminal run record from multiple call sites | Keep single terminal write API; enforce single caller semantics | D | Orchestrator | needs-change | `Mercury/Mercury/AgentExecutionShared.swift:305` |
| `startSummaryRun` terminal handling | Writes run record + emits `.failed`/`.cancelled` events | Delegate to shared canonical terminal pipeline | D | Orchestrator | needs-change | `Mercury/Mercury/AppModel+SummaryExecution.swift:55` |
| `startTranslationRun` terminal handling | Writes run record + emits `.failed`/`.cancelled` events | Delegate to shared canonical terminal pipeline | D | Orchestrator | needs-change | `Mercury/Mercury/AppModel+TranslationExecution.swift:521` |
| `ReaderSummaryView .failed -> finish(.timedOut/.failed)` | Runtime terminal derived from failure reason | Keep runtime terminal projection, sourced from canonical terminal outcome | C | Presentation/Runtime | needs-change | `Mercury/Mercury/Views/ReaderSummaryView.swift:952` |
| `ReaderSummaryView .cancelled -> finish(.cancelled)` | UI consumes cancelled event as terminal | Keep if source is canonical user cancel only | C | Presentation/Runtime | needs-change | `Mercury/Mercury/Views/ReaderSummaryView.swift:981` |
| `ReaderTranslationView .failed -> finish(.timedOut/.failed)` | Runtime terminal derived from failure reason | Keep runtime terminal projection, sourced from canonical terminal outcome | C | Presentation/Runtime | needs-change | `Mercury/Mercury/Views/ReaderTranslationView.swift:558` |
| `ReaderTranslationView .cancelled -> finish(.cancelled)` | UI consumes cancelled event as terminal | Keep if source is canonical user cancel only | C | Presentation/Runtime | needs-change | `Mercury/Mercury/Views/ReaderTranslationView.swift:581` |
| `AgentRuntimeEngine.finish` | Runtime terminal writer (`completed/failed/cancelled/timedOut`) | Keep runtime phase terminal writer only (not semantic source) | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRuntimeEngine.swift:100` |
| `AgentRuntimePolicy.perTaskWaitingLimit` | Runtime waiting limit policy field | Single waiting-capacity source; remove duplicate policy path | E | Runtime | needs-change | `Mercury/Mercury/AgentRunCore.swift:126` |
| `AgentTaskSpec.queuePolicy.waitingCapacityPerKind` | Per-submit waiting capacity override | Avoid semantic overlap with runtime policy; define one source | E | Runtime | needs-change | `Mercury/Mercury/AgentRunCore.swift:40` |
| `AgentRuntimeEngine.submit` uses `spec.queuePolicy.waitingCapacityPerKind` | Effective waiting policy decided by spec, not runtime policy | Runtime policy should be authoritative for waiting capacity | E | Runtime | needs-change | `Mercury/Mercury/AgentRuntimeEngine.swift:44` |
| `AgentRuntimeContract.baselineWaitingCapacityPerKind` | Another waiting-limit knob used in views | Replace with centralized runtime waiting policy | E | Runtime | to-remove | `Mercury/Mercury/AgentRunCore.swift:119` |
| Non-agent tasks (`sync/import/export/bootstrap`) through `enqueueTask` only | Queue-only execution path | Keep queue-only path for non-agent families | Compliant | Queue | as-is | `Mercury/Mercury/AppModel+Sync.swift:129,177,299`; `Mercury/Mercury/AppModel+ImportExport.swift:15,50` |
| `TaskCenter.apply` auto debug issue for any queue `.failed` | Generic failure logging, including agent queue failures | Derive once from canonical terminal projection; avoid duplication with agent debug writes | G | Queue/Presentation | needs-change | `Mercury/Mercury/TaskQueue.swift:530` |
| `recordAgentTerminalOutcome` debug writes | Centralized agent-specific debug projection for failure/timeout/cancel | Keep single agent debug writer; remove competing queue-generic duplicates for agent tasks | G | Orchestrator | needs-change | `Mercury/Mercury/AgentExecutionShared.swift:159` |
| LLM usage on cancellation catches often recorded as `.cancelled` | Timeout may be underreported if surfaced via cancellation | Map usage status from canonical terminal outcome | G | Telemetry | needs-change | `Mercury/Mercury/AppModel+SummaryExecution.swift:311`; `Mercury/Mercury/AppModel+TranslationExecution.swift:791,1095,1271,1407` |

## Immediate Findings Summary

1. Timeout terminal representation exists in queue/runtime/persistence, but terminal-source ownership is still fragmented.
2. Terminal write ownership is distributed across queue catch blocks, shared cancellation helper, execution files, and UI-runtime bridging.
3. Waiting-capacity policy has overlapping knobs (`policy`, `spec.queuePolicy`, `baseline constant`).
4. Diagnostics projection is duplicated (`TaskCenter` generic failed log + `recordAgentTerminalOutcome` agent logs).

## Baseline Acceptance Checklist

- [x] Queue task lifecycle artifacts listed.
- [x] Runtime lifecycle artifacts listed.
- [x] Persistence/telemetry status artifacts listed.
- [x] Agent orchestration terminal-write paths listed.
- [x] Reader projection terminal mapping paths listed.
- [x] Non-agent queue-only path explicitly classified.
- [x] Canonical mapping table implemented in code.
- [ ] Single terminal writer enforcement implemented in code (next step).
