# Swift Concurrency Stabilization Plan

Date: 2026-04-14
Status: Proposed investigation and remediation plan

## 1. Scope

This document records the current working diagnosis for the instability introduced around commit `85272e7` and defines an architecture-first remediation plan.

The immediate symptoms are:

1. Release/archive compiler crashes on older and newer Apple toolchains after the pipeline refactor around `85272e7`.
2. A CI-built Release app crashing at runtime on article activation, especially when a newly selected article has no cached content and must run the full reader pipeline.
3. Swift 6 with Complete strict concurrency surfacing compile-time diagnostics in the same subsystem cluster:
   - `Core/Database/DatabaseManager.swift`
   - `Core/Tasking/JobRunner.swift`
   - `Core/Tasking/TaskQueue.swift`
   - `Feed/AppModel+ImportExport.swift`
   - `Feed/AppModel+Sync.swift`
   - `Reader/ReaderSourceDocumentLoader.swift`

The most important conclusion is that this does **not** currently look like a single feature-logic bug. It looks like a pre-existing concurrency boundary problem that was amplified by the code-shape expansion in the new reader pipeline.

## 2. Working Diagnosis

### 2.1 `85272e7` likely exposed a latent runtime/codegen problem

The pipeline refactor added:

- new pipeline polymorphism
- new intermediate-content persistence
- more async closure injection points
- more temporary fetch and render stages
- more cross-subsystem interaction between reader loading, networking, task execution, and persistence

That change increased the number of async boundaries and generic closure captures in code that was already close to Swift 6 strict-concurrency limits.

### 2.2 The post-`85272e7` fixes are strong evidence of a code-shape issue

Two follow-up commits are especially important:

- `9efabea` changed `ReaderObsidianPipeline` initializers so they no longer rely on default arguments that reference `Self` async/static helpers.
- `4d398ee` changed `JobHandle` from `final class` to `struct` and removed an unnecessary `MainActor.run` hop in `JobRunner`.

Both changes are classic compiler/runtime stabilization moves. They are not business-logic fixes. This strongly suggests that the system is currently sensitive to code shape, actor isolation inference, ARC lifetime, or optimizer behavior across toolchain versions.

### 2.3 The runtime crash signature points to async lifetime/isolation risk

The crash log shows:

- `EXC_BAD_ACCESS`
- possible pointer authentication failure
- the crashing thread in `URLSession.data(from:)` continuation machinery
- concurrent activity in `GRDB.DatabaseQueue`

This is much more consistent with one of the following than with a normal feature bug:

- invalid object lifetime across async suspension
- actor-isolation violation that escaped compile-time enforcement
- unsafe capture of non-sendable state into concurrent work
- compiler-generated miscode triggered by unsupported concurrency shapes

### 2.4 Swift 6 diagnostics should be treated as root-cause signals, not optional cleanup

The current Swift 6 / Complete strict concurrency errors and warnings are aligned with the runtime symptoms. They are not just cosmetic modernization work.

They indicate that:

- background task owners are not cleanly isolated
- non-sendable closures are crossing concurrency domains
- `@MainActor` state is being captured into generic task executors
- temporary network/session lifetimes are coupled to async closure scopes

The right response is to tighten the concurrency architecture, not to suppress diagnostics with narrow annotations.

## 3. Remediation Principles

The implementation strategy should follow these principles.

### 3.1 Fix ownership and isolation first

Do not start by adding isolated annotations only to satisfy the compiler. First decide:

- who owns the work
- where mutable state lives
- which actor or queue is authoritative
- which values are allowed to cross concurrency domains

### 3.2 Prefer explicit execution hosts over ad hoc `Task {}` usage

Background work should be hosted by a dedicated runtime component with explicit lifecycle and termination rules. Avoid creating unstructured tasks from arbitrary model-layer closures.

### 3.3 Avoid temporary async infrastructure whose lifetime depends on optimizer behavior

Objects such as `URLSession`, delegates, streams, and continuation-backed handles should have explicit owners. They should not rely on temporary local variables surviving across complex async suspension chains.

### 3.4 Do not use `@unchecked Sendable` as a first response

`@unchecked Sendable` should be reserved for types whose thread-safety is already structurally guaranteed and documented. It must not be used to bypass genuine architecture problems.

### 3.5 Use Swift 6 diagnostics as the acceptance baseline

Each phase should reduce the strict concurrency diagnostic count by structural cleanup, not by one-off syntax patches.

## 4. Ordered Remediation Plan

The work should proceed in the following order.

## 4.1 Phase 1: Stabilize the Tasking and Database Foundation

This phase should happen before any Reader-specific repair. It addresses the shared infrastructure that all runtime paths depend on.

### File: `Core/Database/DatabaseManager.swift`

#### Diagnosis

`DatabaseManager` currently mixes:

- a reference-type owner
- an internal `DispatchQueue`
- a `GRDB.DatabaseQueue`
- async continuations
- arbitrary database closures supplied by callers

Current read/write methods enqueue work onto a custom `DispatchQueue` and resume a continuation from that queue:

- `read<T>(_:)`
- `write<T>(_:)`

This shape has several problems:

1. The closure passed into `queue.async` is concurrent work, but the database block type is not modeled as `@Sendable`.
2. `self`, `dbQueue`, and the caller-supplied block are all captured into a queue hop that Swift 6 correctly treats as suspicious.
3. `DatabaseManager` is serializing on top of `GRDB.DatabaseQueue`, which already has its own serialization semantics. The extra queue increases indirection without clearly improving safety.
4. The reference-type lifetime and `deinit`-based primary-path unregister logic make object ownership important, but the current API does not make that ownership explicit at concurrency boundaries.

#### Recommended architectural fix

Refactor `DatabaseManager` into a model where concurrency ownership is explicit:

- either make `DatabaseManager` an actor that owns the `DatabaseQueue`
- or keep it as a plain type but remove the extra `DispatchQueue` layer and move async bridging into a dedicated database execution host with a clearly documented boundary

The preferred direction is:

1. One authoritative execution owner for database access.
2. No ad hoc dispatch hop for every read/write call.
3. Database work closures should not cross arbitrary concurrency domains as untyped non-sendable values.
4. The public async API should guarantee that all database execution happens behind one isolation boundary.

#### Concrete repair goals

- Remove the custom `DispatchQueue` if it is not strictly required.
- Make the database execution boundary singular and explicit.
- Avoid capturing arbitrary closures into `DispatchQueue.async`.
- Re-evaluate whether primary database registration should remain tied to `deinit`, or whether tests/runtime should get an explicit shutdown contract.

### File: `Core/Tasking/JobRunner.swift`

#### Diagnosis

`JobRunner` is an actor, but its API still exposes a fragile boundary:

- generic `Result`
- `AsyncStream<JobEvent>`
- `Task<Result, Error>`
- caller-provided `operation` closures

This subsystem already required a code-shape repair:

- `JobHandle` had to move from `final class` to `struct`
- a `MainActor.run` construction hop had to be removed

That is a strong sign that the handle model should be simplified further.

The current risks are:

1. `Result` is unconstrained even though it crosses an actor boundary through the handle and task result path.
2. The event stream and worker task are packaged into a generic handle that is passed out of the actor wholesale.
3. `run(onEvent:)` starts another unstructured `Task` to consume events, which creates another lifetime that is not explicitly owned by the caller.

#### Recommended architectural fix

Keep `JobRunner` small and explicit:

1. Require `Result: Sendable` for APIs that cross the actor boundary.
2. Keep handle types value-based and immutable.
3. Decide whether `JobRunner` should expose:
   - only `run(...) -> Result`, or
   - a more explicit start/stream/await API with clearly owned observation lifecycle

The main design goal is that `JobRunner` should own execution, but not leak ambiguous ownership of event-consumption tasks.

#### Concrete repair goals

- Add explicit sendability constraints where values leave the actor.
- Audit whether `AsyncStream` observation should be caller-owned rather than started from an internal unstructured task.
- Keep the API minimal and structurally deterministic.

### File: `Core/Tasking/TaskQueue.swift`

#### Diagnosis

`TaskQueue` is currently the most important concurrency-risk file in the shared runtime.

Problems in the current design:

1. `QueuedTask.operation` is not modeled as `@Sendable`.
2. `start(_:)` creates an unstructured `Task` from inside the actor and captures:
   - `queuedTask.operation`
   - actor state through `self`
   - task bookkeeping identifiers
3. The closure then calls back into actor methods such as progress updates and finish handling, mixing detached execution with actor-owned mutable state.
4. `events()` installs stream continuations whose lifecycle cleanup is also handled by an internal unstructured `Task`.

This architecture works only if the compiler accepts several implicit assumptions about sendability and actor re-entry. Swift 6 is right to reject or warn about this.

#### Recommended architectural fix

Treat `TaskQueue` as a scheduler actor, not as a place that spawns arbitrary unstructured work without a typed boundary.

The preferred redesign is:

1. The queue actor owns scheduling state.
2. Worker tasks are launched through a narrow, explicitly sendable execution unit.
3. The operation type stored in `QueuedTask` is sendable and does not implicitly carry `@MainActor` state.
4. Progress and termination callbacks are explicitly modeled as sendable crossings back into the queue actor.

If needed, introduce a small helper type such as `TaskQueueExecutor` or a sendable operation wrapper, instead of relying on raw closures with inferred isolation.

#### Concrete repair goals

- Require queued operations to be `@Sendable`.
- Audit every `Task {}` creation in this file and replace implicit ownership with explicit ownership.
- Separate scheduler state mutation from worker execution more clearly.
- Keep cancellation and timeout handling inside a structurally sound task tree.

## 4.2 Phase 2: Fix Main-Actor Capture into Background Task Submission

After the shared foundation is stable, clean up the entry points that currently submit main-actor-owned work into the queue runtime.

### File: `App/AppModel.swift`

#### Diagnosis

`AppModel.enqueueTask(...)` is currently a thin forwarding layer, but it is also the main choke point where `@MainActor` model code hands closures to the background task runtime.

That means the API shape here determines whether callers are encouraged to capture UI state directly into background operations.

#### Recommended architectural fix

Use `AppModel.enqueueTask(...)` as a boundary-normalization layer:

- extract immutable inputs on the caller side before task submission
- avoid passing closures that freely capture `self`
- standardize a submission style where background operations receive only the minimum explicit dependencies they need

The goal is to make the safe pattern the easiest pattern.

### File: `Feed/AppModel+Sync.swift`

#### Diagnosis

This file has many queue submissions with the same structural problem:

- `@MainActor` `AppModel` methods call `enqueueTask`
- the operation closure captures `[weak self]`
- once inside the background task, the closure re-enters `self` repeatedly for:
  - sync state mutation
  - UI/debug reporting
  - refresh calls
  - reserved-feed bookkeeping

This is precisely the kind of boundary Swift 6 surfaces because it is not a real isolation model. It is a main-actor object being partially driven from background execution through weak captures and piecemeal re-entry.

#### Recommended architectural fix

Split responsibilities explicitly:

1. Main-actor preparation:
   - compute immutable inputs
   - reserve IDs
   - create a submission descriptor
2. Background execution:
   - run feed sync use cases with only explicit non-UI dependencies
3. Main-actor projection:
   - report results
   - refresh UI-facing state
   - release reservations

The key improvement is to stop treating `AppModel` as both the UI owner and the execution host.

#### Concrete repair goals

- Move pure execution logic into task/use-case level helpers that do not require `AppModel` capture.
- Keep `AppModel` responsible for projection and state transitions only.
- Replace weak-self queue operations with explicit main-actor handoff points.

### File: `Feed/AppModel+ImportExport.swift`

#### Diagnosis

This file is smaller, but it follows the same anti-pattern as sync:

- queue submissions capture `[weak self]`
- the background closure then reaches back into `self` and main-actor-owned state

Because this file is simpler, it should be used as the first cleanup template for the AppModel submission pattern.

#### Recommended architectural fix

Refactor import/export task submission to:

1. extract immutable parameters up front
2. submit a background operation that does not require `AppModel` ownership
3. return to the main actor only for state refresh or user-visible projection

This file is a good pilot because it can demonstrate the desired style before the larger sync file is rewritten.

## 4.3 Phase 3: Stabilize Reader Networking and Pipeline Execution

Only after the shared runtime is structurally sound should the Reader-specific crash path be addressed.

### File: `Reader/ReaderSourceDocumentLoader.swift`

#### Diagnosis

This file is one of the strongest runtime-crash suspects.

Current shape:

- `fetch(...)` is `@MainActor`
- it delegates execution to `jobRunner.run`
- inside the job closure it constructs:
  - a temporary delegate object
  - a temporary ephemeral `URLSession`
  - `defer { session.invalidateAndCancel() }`
- it then awaits `session.data(from:)`

This means the session, delegate, and callback chain all depend on the lifetime of local variables inside a complex async closure executed through `JobRunner`.

That can be correct in theory, but it is fragile in practice, especially across older Release toolchains and optimizer/codegen differences.

#### Recommended architectural fix

Move reader document loading to an explicit loader owner with stable lifetime.

Preferred direction:

- introduce a dedicated reader network loader actor or reference type that owns the `URLSession` and delegate lifecycle
- keep redirect handling inside that loader owner
- make one fetch request a method call on a stable object, not an ad hoc local session assembled inside a temporary async closure

This change is architectural, not cosmetic. It reduces the chance that runtime correctness depends on optimizer-sensitive temporary object lifetime.

#### Concrete repair goals

- Remove local session/delegate construction from the innermost async closure.
- Give redirect handling an explicit owner.
- Make fetch lifecycle and cancellation semantics obvious.

### File: `Reader/ReaderObsidianPipeline.swift`

#### Diagnosis

This file already demonstrated compiler sensitivity through the initializer-default fix in `9efabea`.

It also contains more temporary network infrastructure:

- `fetchMarkdown(url:)` creates a local session
- `fetchResourceIndex(url:)` creates a local session

These helpers are simpler than `ReaderSourceDocumentLoader`, but they still repeat the same lifetime pattern. They also live inside a pipeline type that already has a high generic/closure/async surface area.

#### Recommended architectural fix

Do not keep network fetching as static helper functions on the pipeline type.

Instead:

1. move Obsidian fetch operations behind a dedicated dependency object or loader actor
2. inject that dependency into the pipeline as a stable capability
3. keep the pipeline focused on pipeline decisions and content transformation, not transport ownership

This will reduce both:

- compiler complexity in the pipeline type
- runtime sensitivity of temporary network objects

#### Concrete repair goals

- Separate transformation logic from transport logic.
- Keep initializer shapes simple and explicit.
- Avoid static async helper defaults inside pipeline initializer signatures.

### File: `Reader/ReaderBuildPipeline.swift`

#### Diagnosis

`ReaderBuildPipeline` now coordinates:

- content lookup
- cache lookup
- pipeline selection
- source fetch
- pipeline resolution
- persistence
- rendering
- debug event accumulation

The logic is coherent, but the execution surface is wide. It should not also be responsible for subtle ownership of loader objects and callback lifetimes.

#### Recommended architectural fix

Keep this type as an orchestration layer only.

That means:

- pipeline selection stays here
- rebuild policy stays here
- persistence/render sequencing stays here
- transport/session ownership moves out
- pipeline-specific fetch dependencies move out

This reduction in responsibility should make the code easier for both Swift 6 checking and Release optimization to reason about.

### Optional follow-up files

These files may require small follow-up adjustments after the main phases above:

- `Reader/ReaderPipeline.swift`
- `Reader/AppModel+Reader.swift`
- `Core/Database/ContentStore.swift`

Those changes should be driven by the architectural cleanup above, not by standalone warning suppression.

## 5. Repair Style Rules

The following rules should govern implementation work.

1. Do not fix this by sprinkling `@MainActor` on background execution code.
2. Do not fix this by adding `@unchecked Sendable` unless the safety argument is explicit and documented.
3. Do not preserve unstable code shape just because it currently passes one toolchain.
4. Prefer extracting stable owners and explicit boundaries over local annotation tricks.
5. When a closure crosses a concurrency boundary, its dependencies must be explicit and intentionally sendable.

## 6. Verification Plan

Each remediation phase should be validated in the following order.

### 6.1 Compile-time verification

1. Build with `SWIFT_VERSION = 6.0`.
2. Treat Complete strict concurrency diagnostics as blocking signals in the targeted files for that phase.
3. Re-check both Debug and Release build paths after each phase.

Additional rule:

- During the implementation phases, local Swift 6 compile-time cleanliness is the main gate. CI should not be used as a routine probe for every small edit.

### 6.2 Runtime verification

At minimum, verify:

1. app launch from a CI-built Release app
2. selecting a normal uncached article
3. selecting an uncached Obsidian-backed article
4. repeated entry switching while reader pipeline work is in flight
5. no startup crash and no click-to-open crash

Execution policy:

1. After a file-level or tightly related group of changes, first require local `Swift 6` compile/static-analysis cleanliness.
2. After each phase-level checkpoint, perform one manual local Debug smoke test.
3. At the same checkpoint, perform one manual local Release smoke test.
4. Focus the smoke test on previously known failure points instead of broad exploratory regression.
5. Reserve CI-built runtime validation for the point where all targeted files in this document have been completed.

This policy is intentional. The current runtime crash is not reliably reproducible locally, so the process should minimize expensive CI-only discovery loops by raising the local compile-time bar first.

### 6.3 Toolchain verification

Because the observed failures differ by Xcode/Swift version, each stabilization pass should be checked against:

- local toolchain archive/build
- CI toolchain archive/build
- runtime behavior of the CI-produced app on the target machine

Archive success alone is not sufficient. The runtime behavior of the CI-produced app remains a required signal.

### 6.4 CI usage rule

CI validation should be treated as the final cross-toolchain and packaged-artifact check, not as the primary day-to-day debugging mechanism.

The preferred sequence is:

1. local Swift 6 compile and static-analysis cleanup
2. local Debug smoke test at phase checkpoint
3. local Release smoke test at phase checkpoint
4. CI-built app verification after the full targeted remediation set is complete

If an intermediate CI run becomes necessary, it should be a conscious exception with a clear reason, not the default workflow.

## 7. Post-Fix Risk Scan Requirement

After the currently identified compile-time concurrency issues in the target files are resolved, the project must perform one broader scan for similar high-risk code shapes in adjacent modules.

This is a mandatory follow-up step, not an optional cleanup pass.

### 7.1 Why this follow-up scan is required

Swift 6 Complete strict concurrency diagnostics are the best first-line signal available, and they should be trusted as the primary backlog driver.

However, they are not a complete oracle for:

- Release-only optimizer-sensitive bugs
- lifetime-sensitive async resource ownership issues
- code shapes that are legal enough to compile but still fragile across toolchains

Therefore, "Swift 6 did not flag it" is sufficient to lower priority, but not sufficient to prove safety for nearby modules that use the same execution patterns.

### 7.2 Scope of the follow-up scan

The scan should be limited and pattern-driven. It should not become an open-ended rewrite of unrelated modules.

The purpose is to find code that resembles the repaired problem shapes in:

- task execution
- actor boundaries
- queue hopping
- async resource lifetime
- `@MainActor` capture into background work

### 7.3 High-risk patterns to scan for

The follow-up scan must look for at least the following patterns:

1. `Task {}` or other unstructured task creation that captures `self` from `@MainActor` types or actor-owned state.
2. `DispatchQueue.async`, `asyncAfter`, or equivalent queue hops that capture non-sendable closures, stores, database handles, sessions, or model owners.
3. `withCheckedContinuation` and `withCheckedThrowingContinuation` usages whose ownership or resumption boundary is not explicit.
4. `AsyncStream` / continuation-based event plumbing with ambiguous consumer lifetime or cleanup ownership.
5. Temporary `URLSession` plus delegate plus `await session.data(...)` patterns whose correctness depends on local async variable lifetime.
6. Actor APIs that store, forward, or execute closures not explicitly modeled as `@Sendable`.
7. Initializer default arguments that reference `Self` async or static helpers in concurrency-heavy types.
8. Background task closures that repeatedly re-enter `@MainActor` objects through weak captures instead of using explicit projection boundaries.

### 7.4 Acceptance rule for the follow-up scan

The scan does not require immediate remediation of every suspicious site in the repository.

It does require:

1. identifying any additional sites that strongly resemble the repaired problem class
2. classifying them by risk
3. either fixing the clearly risky ones or recording them as the next explicit stabilization backlog

The key rule is that the current remediation must not conclude with known duplicate patterns left completely unreviewed.

## 8. Suggested Execution Order

If the work is split into implementation passes, the preferred sequence is:

1. `DatabaseManager.swift`
2. `JobRunner.swift`
3. `TaskQueue.swift`
4. `AppModel.swift` task submission boundary
5. `AppModel+ImportExport.swift`
6. `AppModel+Sync.swift`
7. `ReaderSourceDocumentLoader.swift`
8. `ReaderObsidianPipeline.swift`
9. `ReaderBuildPipeline.swift` follow-up simplification

This order is designed to remove the highest-leverage concurrency and lifetime hazards first, before revisiting the reader pipeline crash path directly.

## 9. Execution Batches

Implementation should be grouped into the following batches instead of being performed as nine isolated single-file edits or one large all-at-once rewrite.

The purpose of batching is:

1. keep each checkpoint large enough to reflect a real architectural layer
2. keep each checkpoint small enough to preserve reasonable blame and rollback scope
3. trigger local smoke testing only at meaningful integration boundaries

### Batch 1: Shared Foundation

Files:

- `Core/Database/DatabaseManager.swift`
- `Core/Tasking/JobRunner.swift`
- `Core/Tasking/TaskQueue.swift`

Goal:

- stabilize the shared concurrency and execution substrate before touching higher-level feature entry points

Checkpoint action:

- after this batch, perform one local Debug smoke test and one local Release smoke test

### Batch 2: Main-Actor Task Submission Boundary

Files:

- `App/AppModel.swift`
- `Feed/AppModel+ImportExport.swift`
- `Feed/AppModel+Sync.swift`

Goal:

- separate `@MainActor` UI ownership from background task execution

Checkpoint action:

- after this batch, perform one local Debug smoke test and one local Release smoke test

### Batch 3: Reader Networking Lifetime

Files:

- `Reader/ReaderSourceDocumentLoader.swift`
- `Reader/ReaderObsidianPipeline.swift`

Goal:

- stabilize networking, delegate ownership, and async resource lifetime on the reader fetch path

Checkpoint action:

- after this batch, perform one local Debug smoke test and one local Release smoke test, focused on uncached article activation

### Batch 4: Reader Orchestration Cleanup

Primary file:

- `Reader/ReaderBuildPipeline.swift`

Expected related follow-up files when required by the orchestration cleanup:

- `Reader/ReaderPipeline.swift`
- `Reader/AppModel+Reader.swift`
- `Core/Database/ContentStore.swift`

Goal:

- simplify the reader orchestration layer after the lower-level execution and networking fixes are in place

Checkpoint action:

- after this batch, perform the final local Debug and Release smoke tests before CI-built artifact validation

## 10. Current Progress

Current status on the product target:

- Batch 1 has been completed, and its changes also pulled a few adjacent shared/template boundary fixes forward because Swift 6 surfaced them as part of the same foundation layer.
- Batch 2 has been completed. `AppModel` task submission for sync, bootstrap, and import/export now uses explicit dependency capture plus explicit main-actor projection instead of background closures repeatedly driving `AppModel` through weak captures.
- Batch 3 has been completed. Reader source fetching and Obsidian remote fetches now execute through explicit fetch-owner objects, and the default build-pipeline source-document path retains a stable loader instance instead of constructing temporary session/delegate infrastructure inside the innermost async closure.
- Batch 4 has been completed. `ReaderBuildPipeline` now reads persisted reader state and writes content/cache state through `ContentStore` helpers, so the pipeline stays focused on action selection, fetch/build sequencing, and failure projection instead of row construction and persistence assembly.
- The Mercury app target now builds cleanly under `SWIFT_VERSION = 6.0` in local Debug validation, with no product-target compiler errors or warnings.
- Test-target synchronization has been intentionally deferred until all four product-code batches are complete, to avoid paying the test-fix cost multiple times while core signatures are still moving.

Implication:

- the next implementation step should synchronize the test target with the finalized product-code signatures and execution boundaries
- after test synchronization, run the planned repository-wide risk-pattern scan before CI-built artifact validation
