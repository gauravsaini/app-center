# Operation State Machine — the complete contract

> Status: DECIDED. This document is the authority on `OperationHandle`.
> LLD §3 defers to it. Backends implement it; the exam enforces it.

One install/update/remove = one handle = one state machine.
The UI binds to this and nothing else.

---

## 1. States

### Non-terminal

| State | Payload | Meaning |
|---|---|---|
| `queued` | `position: int` | Waiting for an engine slot. `position: 0` = next to run. |
| `restoring` | — | Re-attached after app restart to an operation the backend reports still running. Emitted once, then normal phases resume. |
| `authenticating` | — | Privilege prompt (polkit) in flight. |
| `preparing` | — | Backend getting ready: dependency resolution, disk-space preflight, sanity checks. |
| `downloading` | `bytesDone: int`, `bytesTotal: int?` | Fetching payload. `bytesTotal: null` = size unknown → UI shows indeterminate. |
| `verifying` | — | Checksum/signature verification. OPTIONAL — backends may skip it entirely. |
| `applying` | `fraction: double?` | Mutating the system (linking, unpacking, removing). `fraction: null` = indeterminate. Named `applying`, not `installing` — it must read honestly for remove/update too. |
| `cancelling` | — | Cancel requested, backend winding down. Transitional: the UI shows "Cancelling…" instead of lying that work is still progressing. |

### Terminal

| State | Payload | Meaning |
|---|---|---|
| `done` | `result: OperationResult` | Completed. See §5. |
| `cancelled` | — | Did not complete. INVARIANT: the system is unchanged — the backend cleaned up partial work (downloads removed, locks released). |
| `failed` | `error: StoreException` | Did not complete. `error` is ALWAYS a typed `StoreException` (§7). Raw stderr never reaches the UI. |

---

## 2. Legal transitions — the DAG

Phases may be **skipped forward freely** (a remove has no `downloading`;
a backend may skip `verifying`), but a phase is **never re-entered** once
left. Self-transitions are allowed only for progress updates.
One exception: `queued → done` is legal **only** when the result carries
`noop: true` — the honest no-op (already installed, nothing fetched,
nothing changed). A non-noop `done` must arrive via a real phase path.

```
queued         → authenticating | preparing | downloading | verifying
                 | applying | cancelling | failed
restoring      → authenticating | preparing | downloading | verifying
                 | applying | cancelling | failed
authenticating → preparing | downloading | verifying | applying
                 | cancelling | failed
preparing      → authenticating | downloading | verifying | applying
                 | cancelling | failed
downloading    → downloading | verifying | applying | cancelling | failed
verifying      → applying | cancelling | failed
applying       → applying | cancelling | done | failed
cancelling     → cancelled | done | failed
done | cancelled | failed → (no outgoing transitions)
```

Notes:

- `preparing → authenticating` is legal: some backends discover they need
  elevation only after resolving the transaction (e.g. flatpak user-vs-system).
- `downloading → downloading` and `applying → applying` are progress updates
  with new payloads, not phase changes.
- `cancelling → done`: the operation passed the **point of no return**
  (e.g. dpkg mid-configure) and completed before the cancel took effect.
  `result.cancelRequested` is then `true` so the UI can say so honestly.
- `cancelling → failed`: only if the wind-down itself failed. The original
  context is preserved in `error.debugDetail`. A backend MUST NOT convert a
  user cancel into a generic failure.
- Terminal states emit no further events. Ever.

---

## 3. `cancel()` semantics

- Safe to call in **any** state. No-op when already terminal.
- From `queued`: dequeue immediately → `cancelling` → `cancelled`.
- From any other non-terminal state: → `cancelling`, then terminal.
- Backend MUST reach a terminal state within **2s** of `cancel()`.
- Calling `cancel()` while `cancelling` is a no-op.
- Cooperative but prompt: if the backend cannot interrupt the current
  atomic unit, it finishes the unit, then honours the cancel.

---

## 4. Progress rules

- `downloading`: `bytesDone` is monotonic non-decreasing within an operation;
  `bytesDone <= bytesTotal` whenever the total is known.
- `applying`: `fraction` in `[0,1]`, monotonic non-decreasing; `null` means
  indeterminate (UI shows spinner + phase label).
- Backends MUST NOT fabricate progress. No fake 99%.
- **Heartbeat:** during `downloading`/`applying`, the backend emits a state
  event at least every 60s even if nothing changed.
- **Watchdog:** if the engine sees no event for `engine.stall_timeout`
  (default 10 min, flag-controlled), it calls `cancel()`; if no terminal
  state follows within 30s, the handle goes to
  `failed(TimeoutException)`.

---

## 5. `OperationResult` — the `done` payload

```dart
class OperationResult {
  final String? installedVersion; // version now on system, if known
  final bool requiresRestart;     // default false (kernel/driver updates)
  final bool noop;                // default false: already in desired state,
                                  // nothing changed, no download happened
  final bool cancelRequested;     // default false: user asked to cancel but
                                  // the op was past the point of no return
}
```

---

## 6. Idempotency

- `install` on an already-installed app → `done(noop: true)`. No re-download.
- `remove` on a not-installed app → `done(noop: true)`.
- `update` with nothing to update → `done(noop: true)`.
- If a backend cannot detect the no-op cheaply, it MAY return
  `failed(ConflictException)` instead — but `noop: true` is preferred.

---

## 7. Error taxonomy — `StoreException`

```dart
sealed class StoreException implements Exception {
  String get code;              // stable, for telemetry + i18n: 'network', …
  String get debugDetail;       // developer English, logs only
  Remediation get remediation;  // structured next step — not a string
  String? get backendId;        // which backend raised it
  bool get retryable;           // derived: remediation == Remediation.retry
}

enum Remediation { retry, freeSpace, checkNetwork, fixBackend, reportBug, none }
```

| Exception | `code` | Carries | Remediation |
|---|---|---|---|
| `NetworkException` | `network` | `attemptedHost?` | `retry` |
| `AuthException` | `auth_denied` / `auth_dismissed` / `auth_expired` | — | `none` (quiet note, no nagging) |
| `DiskSpaceException` | `disk_full` | `neededBytes`, `availableBytes` | `freeSpace` |
| `DependencyException` | `dependency` | `details: List<String>` | `none` |
| `VerificationException` | `verification` | `expected?`, `actual?` | `retry` |
| `BackendUnavailableException` | `backend_unavailable` | — | `fixBackend` |
| `PermissionException` | `confinement` | `neededAccess` | `fixBackend` |
| `AppNotFoundException` | `not_found` | — | `none` |
| `ConflictException` | `conflict` | — | `none` |
| `InterruptedException` | `interrupted` | — | `retry` |
| `TimeoutException` | `timeout` | `stalledPhase` | `retry` |
| `UnknownStoreException` | `unknown` | `rawOutput` (for bug reports) | `reportBug` |

Rules:

- Every backend maps its native errors into this taxonomy. `failed` states
  carry these; the host renders localized messages + affordances
  (Retry for `retry`, disk settings for `freeSpace`, nothing but a quiet
  note for auth-denied).
- Telemetry counts by `code`, never by message text.
- `UnknownStoreException` is a bug-report generator, not a user message.

---

## 8. Engine rules

- **One active operation per `AppIdentity`.** A second `enqueue` for the same
  app returns the EXISTING handle (no duplicate downloads, no double
  polkit prompts).
- **One mutating operation per backend at a time**
  (`engine.max_concurrent_per_backend`, default 1 — dpkg locks make this
  mandatory for deb; the others follow for sanity). The rest wait in
  `queued` with honest `position` values.
- **Auth coalescing:** batch N queued ops into one privilege prompt where
  the vehicle allows. Never prompt twice for one user gesture.
- Terminal handles are retained for `engine.history_ttl` (default 24h)
  for the Manage-page history, then evicted.

---

## 9. Crash recovery

- Handles are **session-scoped**. They do not survive app restart.
- On boot, the engine calls `StoreBackend.recoverInFlight()` on each
  backend. Backends that can (snapd: query changes in `Doing` state)
  return re-attached handles; others return empty.
- A re-attached handle emits `restoring()` once, then resumes at the
  backend-reported phase.
- Operations the backend does NOT report are simply gone — the user can
  retry. No phantom progress.

---

## 10. Dart sketch

```dart
abstract class OperationHandle {
  String get id;
  AppIdentity get app;
  OperationKind get kind;              // install | remove | update
  Stream<OperationState> get state;  // updates; terminal states emit nothing further
  OperationState get current;        // latest state, synchronously

  /// Request cancellation. Safe in any state; no-op when terminal.
  /// Backend reaches a terminal state within 2s.
  Future<void> cancel();
}

@freezed
class OperationState with _$OperationState {
  const factory OperationState.queued({required int position}) = Queued;
  const factory OperationState.restoring() = Restoring;
  const factory OperationState.authenticating() = Authenticating;
  const factory OperationState.preparing() = Preparing;
  const factory OperationState.downloading({
    required int bytesDone,
    int? bytesTotal,                   // null = unknown → indeterminate
  }) = Downloading;
  const factory OperationState.verifying() = Verifying;
  const factory OperationState.applying({double? fraction}) = Applying;
  const factory OperationState.cancelling() = Cancelling;
  const factory OperationState.done({required OperationResult result}) = Done;
  const factory OperationState.cancelled() = Cancelled;
  const factory OperationState.failed({required StoreException error}) = Failed;
}
```

---

## 11. Contract exam assertions

`store_contracts` ships these; every backend MUST pass:

1. `install` → first state is `queued` (or `restoring` for re-attached).
2. Recorded transitions form a legal path through the DAG in §2.
   A fake emitting `downloading → queued` fails the exam.
3. `cancel()` from each non-terminal phase → terminal within 2s;
   terminal ∈ {`cancelled`, `done`}; never a bare `failed`.
4. Progress monotonicity: `bytesDone` / `fraction` never decrease.
5. Every `failed` carries a `StoreException` with non-empty `code` and
   `debugDetail`.
6. Double `enqueue` for the same app → same handle id.
7. Terminal silence: after `done`/`cancelled`/`failed`, no events for 500ms.
8. Install on installed app → `done` with `noop: true`, no download phase.
9. `recoverInFlight` handles (if any) start with `restoring`.
10. `isAvailable()` < 200ms, no side effects, callable twice safely.

---

*The state machine is the product. Everything the user feels — honesty about
progress, cancellation that works, errors that explain themselves — is
decided here, not in the UI.*
