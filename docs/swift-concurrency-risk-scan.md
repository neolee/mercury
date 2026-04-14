# Swift Concurrency Follow-up Risk Scan

Date: 2026-04-14
Status: Follow-up scan completed and medium-risk backlog addressed

## Scope

This report is the pattern-driven follow-up scan requested by [docs/swift-concurrency.md](./swift-concurrency.md).

The scan was intentionally limited to product code and to shapes that resemble the already repaired problem class:

- unstructured task creation around actor or main-actor state
- queue hops that capture owners or stateful resources
- `AsyncStream` continuation ownership and cleanup
- temporary `URLSession` plus delegate plus `await` lifetime patterns
- remaining `@unchecked Sendable` boundaries

The goal of this scan is not to trigger another broad rewrite. The goal is to identify any remaining duplicate patterns that are close enough to the repaired Swift 6 / runtime-stability problem class to deserve explicit review.

## Summary

- No additional high-risk duplicate of the previously repaired reader/tasking crash shape was found in the active product path.
- The two medium-risk sites identified by the scan have now been remediated and revalidated locally.
- Several lower-risk patterns were reviewed and are currently acceptable because ownership is explicit or because they are UI/AppKit readiness bridges rather than background execution boundaries.

## Resolution Update

The two explicit follow-up backlog items from the initial scan have been addressed:

1. `SyncService` ATS diagnostic probing now runs through an explicit probe-host owner instead of a temporary delegate plus temporary `URLSession` lifetime shape.
2. `SidebarCountStore` observation delivery now uses a single main-actor delivery boundary instead of `.async(onQueue: .main)` followed by an extra `Task { @MainActor ... }` hop.

Validation completed after these fixes:

- focused sidebar and sync-related MercuryTest suites passed
- repository-standard `./scripts/build` passed
- repository-standard `./scripts/test` passed
- local Release build passed

## Resolved Medium-Risk Findings

### 1. Temporary `URLSession` plus delegate probe path still exists in sync diagnostics

File:

- `Mercury/Feed/SyncService.swift:221`

Why it matters:

- `probeRequestDiagnostics(for:)` constructs a local `RedirectCaptureDelegate`, a local ephemeral `URLSession`, and then awaits `session.data(for:)`.
- This is the same general shape called out in the main plan: correctness depends on a temporary async resource owner surviving suspension.
- The path is diagnostic-only and not on the main feed-sync happy path, so this is lower risk than the previously repaired reader fetch path.
- Even so, it is still the clearest remaining duplicate of the old lifetime-sensitive pattern.

Resolution:

- Fixed on 2026-04-14 by introducing an explicit `SyncDiagnosticProbeHost` owner for the probe session and redirect capture lifecycle.

Completion note:

- The probe path now uses an explicit fetch-owner helper, matching the intended post-stabilization shape closely enough that no further action is currently queued.

## 2. Sidebar observation still performs a double main-thread hop

File:

- `Mercury/Feed/SidebarCountStore.swift:39`

Why it matters:

- The observation is already scheduled with `.async(onQueue: .main)`.
- The `onChange` callback then creates another unstructured `Task { @MainActor ... }` before assigning `projection`.
- This is not the same severity as the previous runtime crash class, but it does create an unnecessary extra scheduling boundary.
- The recent test flake in `SidebarCountStoreTests` is strong evidence that this shape is operationally noisy even if it is not unsafe.

Resolution:

- Fixed on 2026-04-14 by removing the extra `Task` hop and updating the projection directly on the existing main-actor delivery boundary.

Completion note:

- The observation callback now uses a single delivery boundary and is no longer queued for follow-up work.

## Low-Risk Findings Reviewed and Currently Acceptable

### 1. AsyncStream event centers have explicit owner cleanup

Files:

- `Mercury/Agent/Runtime/AgentRuntimeEngine.swift:214`
- `Mercury/Agent/Tagging/AppModel+TagBatchExecution.swift:91`
- `Mercury/Core/Tasking/TaskQueue.swift`
- `Mercury/Core/Tasking/JobRunner.swift`

Why they were reviewed:

- These files still use `AsyncStream` continuations and `onTermination` cleanup hooks.
- That is one of the documented follow-up scan patterns.

Why they are currently acceptable:

- Continuation storage is actor- or owner-scoped.
- Cleanup ownership is explicit.
- These are no longer ad hoc event pipelines with ambiguous lifetime.
- Their shape matches the intended post-remediation architecture much more closely than the pre-fix tasking/runtime code did.

Current assessment:

- Risk: low.
- No immediate remediation required.

### 2. UI `DispatchQueue.main.async` usage is mostly AppKit readiness bridging

Representative files:

- `Mercury/App/Views/SearchFieldWidthCoordinator.swift:36`
- `Mercury/Core/Views/TextEditorEx.swift:120`
- `Mercury/Digest/Views/EntryNoteEditorView.swift:43`
- `Mercury/App/Views/ContentView+Commands.swift:27`
- `Mercury/Agent/Settings/AgentSettingsView+Model.swift:317`
- `Mercury/Agent/Settings/AgentSettingsView+Provider.swift:268`

Why they were reviewed:

- The scan explicitly called for queue-hop review.

Why they are currently acceptable:

- These sites are UI focus/layout scheduling bridges tied to AppKit view/window readiness.
- They do not forward non-sendable background work into execution subsystems.
- They do not resemble the repaired database/task/runtime ownership problems.

Current assessment:

- Risk: low.
- Keep them out of the stabilization backlog unless they cause concrete UI defects.

## Previously Risky Shapes That Now Look Correctly Contained

### Reader fetch ownership

Files:

- `Mercury/Reader/ReaderSourceDocumentLoader.swift:3`
- `Mercury/Reader/ReaderObsidianPipeline.swift:3`

Assessment:

- These files were reviewed specifically because the older crash path lived in this neighborhood.
- They now use explicit fetch-owner objects with owned `URLSession` lifetime instead of constructing the most dangerous temporary shapes directly inside the innermost async closure.
- This is consistent with the intended stabilization direction and is not currently a backlog candidate.

### Remaining `@unchecked Sendable`

Files reviewed:

- `Mercury/Core/Database/DatabaseManager.swift`
- `Mercury/Core/Tasking/JobRunner.swift`
- `Mercury/Reader/ReaderSourceDocumentLoader.swift`
- `Mercury/Reader/ReaderObsidianPipeline.swift`
- `Mercury/Feed/SyncService.swift`

Assessment:

- The remaining usages are concentrated in owner/helper types rather than spread arbitrarily across feature code.
- Most are structurally narrow and consistent with the stabilized design.
- `SyncService` is the only one from this group that still overlaps with a medium-risk duplicate lifetime pattern.

## Recommended Next-Step Backlog

No additional medium-risk duplicate of the repaired problem class is currently queued from this scan.

If further work continues in this area, the next sensible step is not another architecture rewrite. It is a narrow validation follow-up:

1. keep the remaining low-risk reviewed sites under observation during normal feature work
2. defer any new concurrency hardening unless new Swift 6 diagnostics, Release-only failures, or CI/toolchain-specific regressions appear

## Conclusion

This follow-up scan did not reveal another hidden cluster comparable to the original Swift 6 / runtime-stability problem, and the two medium-risk follow-up items identified by the scan have already been repaired.

That means this phase can be treated as a completed stabilization milestone rather than the start of another broad concurrency migration.