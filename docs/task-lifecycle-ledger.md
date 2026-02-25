# Task Lifecycle Ledger (Step 0 Baseline)

Date: 2026-02-25
Owner: Lifecycle refactor stream
Status: Baseline inventory complete (implementation not started)

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
| `AppTaskKind` | Queue task kind enum (includes agent + non-agent) | Projection from canonical `UnifiedTaskKind` into queue domain | B | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:11` |
| `AgentTaskKind` | Runtime task kind enum for owner/slot orchestration | Agent-only runtime projection from canonical kind | B | Runtime | needs-change | `Mercury/Mercury/AgentRunCore.swift:3` |
| `AgentTaskType` | Persisted DB task type enum | Persistence projection from canonical kind | B | Persistence | needs-change | `Mercury/Mercury/Models.swift:11` |
| `TaskQueue.enqueue` generated `UUID` | Creates queue-local task identity | Consume pre-created canonical task ID | A | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:241` |
| `AgentTaskSpec.taskId = UUID()` default | Runtime spec can create independent ID | Must require caller-supplied canonical task ID | A | Runtime | needs-change | `Mercury/Mercury/AgentRunCore.swift:57` |
| `SummaryRunEvent.started(UUID)` | Emits queue task ID to UI flow | Emit canonical task ID | A | Orchestrator | needs-change | `Mercury/Mercury/AppModel+SummaryExecution.swift:21` |
| `TranslationRunEvent.started(UUID)` | Emits queue task ID to UI flow | Emit canonical task ID | A | Orchestrator | needs-change | `Mercury/Mercury/AppModel+TranslationExecution.swift:11` |
| `AgentRuntimeEngine` fallback `UUID()` in emits | Generates synthetic IDs when state/spec missing | Never synthesize IDs; require canonical ID presence | A | Runtime | needs-change | `Mercury/Mercury/AgentRuntimeEngine.swift:48,87,115,145,164,225` |
| `AppTaskState` (`queued/running/succeeded/failed/cancelled`) | Queue-visible lifecycle without explicit `timedOut` terminal | Queue projection must include explicit timeout terminal | C | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:114` |
| `AgentRunPhase` includes `.timedOut` | Runtime terminal phase can represent timeout | Keep as runtime projection of canonical terminal | Compliant | Runtime | as-is | `Mercury/Mercury/AgentRunCore.swift:9` |
| `AgentTaskRunStatus` (`queued/running/succeeded/failed/cancelled`) | Persisted run status lacks timeout terminal | Add timeout-capable terminal projection | C | Persistence | needs-change | `Mercury/Mercury/Models.swift:17` |
| `LLMUsageRequestStatus` includes `.timedOut` | Telemetry can represent timeout | Keep mapped from canonical terminal outcome | Compliant | Telemetry | as-is | `Mercury/Mercury/Models.swift:31` |
| `AppTaskTerminationReason` (`userCancelled/timedOut`) | Side channel reason attached to cancellation flow | Input signal only; not terminal outcome source | D | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:34` |
| `AppTaskCancellationContext` task-local reason provider | Lets downstream infer cancel reason | Keep as low-level cancellation context only | D | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:39` |
| `TaskQueue.withExecutionTimeout` | Enforces deadline by throwing timeout error + cancellation | Keep execution deadline owner; emit canonical timeout signal | Compliant | Queue | as-is | `Mercury/Mercury/TaskQueue.swift:368` |
| `TaskQueue.start catch CancellationError -> .cancelled` | Timeout cancellation collapses into cancelled state | Distinguish timeout vs user-cancel terminal state | C | Queue | needs-change | `Mercury/Mercury/TaskQueue.swift:356` |
| `resolveAgentCancellationOutcome` | Re-infers timeout/user-cancel from task-local reason (nil=>timeout) | Remove inference; consume explicit canonical terminal signal | D | Orchestrator | needs-change | `Mercury/Mercury/AgentExecutionShared.swift:73` |
| `handleAgentCancellation` timeout path writes run `status: .failed` | Timeout persisted as failed | Persist timeout terminal as timeout | C | Orchestrator/Persistence | needs-change | `Mercury/Mercury/AgentExecutionShared.swift:111` |
| `handleAgentCancellation` user-cancel path writes run `status: .cancelled` | User cancel persisted distinctly | Keep, mapped from canonical terminal | Compliant | Orchestrator/Persistence | as-is | `Mercury/Mercury/AgentExecutionShared.swift:177` |
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
| Summary/translation explicit `reportDebugIssue` on failures | Agent-specific debug writes | Keep one projection policy; avoid duplicate + conflicting issue records | G | Orchestrator | needs-change | `Mercury/Mercury/AppModel+SummaryExecution.swift:179`; `Mercury/Mercury/AppModel+TranslationExecution.swift:652`; `Mercury/Mercury/AgentExecutionShared.swift:166,209` |
| LLM usage on cancellation catches often recorded as `.cancelled` | Timeout may be underreported if surfaced via cancellation | Map usage status from canonical terminal outcome | G | Telemetry | needs-change | `Mercury/Mercury/AppModel+SummaryExecution.swift:311`; `Mercury/Mercury/AppModel+TranslationExecution.swift:791,1095,1271,1407` |

## Immediate Findings Summary

1. Identity is not strictly single-source (`TaskQueue` and runtime can each mint IDs).
2. Timeout terminal semantics are fragmented (`Queue` collapse, runtime has timeout, persistence lacks timeout).
3. Terminal write ownership is distributed across queue catch blocks, shared cancellation helper, execution files, and UI-runtime bridging.
4. Waiting-capacity policy has overlapping knobs (`policy`, `spec.queuePolicy`, `baseline constant`).
5. Diagnostics projection is duplicated (`TaskCenter` generic failed log + agent-specific logs).

## Baseline Acceptance Checklist

- [x] Queue task lifecycle artifacts listed.
- [x] Runtime lifecycle artifacts listed.
- [x] Persistence/telemetry status artifacts listed.
- [x] Agent orchestration terminal-write paths listed.
- [x] Reader projection terminal mapping paths listed.
- [x] Non-agent queue-only path explicitly classified.
- [ ] Canonical mapping table implemented in code (next step).
- [ ] Single terminal writer enforcement implemented in code (next step).

