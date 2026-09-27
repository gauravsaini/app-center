# Update progress + cancel UX — HLD + LLD

Parent: [operation-state-machine.md](operation-state-machine.md),
[updates-strangle.md](updates-strangle.md), [manage-strangle-hld.md](manage-strangle-hld.md).

Slice: the unified Updates surface shows live per-operation progress and a
working cancel affordance. The install/remove path already has this
(`UnifiedInstallButton._InFlightControls`); the Updates surface (per-row
updates + update-all) drops handles and shows boolean-only feedback.
This leaf closes that gap without touching the engine or any backend.

## HLD

### 1. Goal

On the unified Updates surface (behind `pages.updates.unified`, default
off), every in-flight update shows:

- **Live progress** — determinate bar when the backend reports byte
  progress, indeterminate otherwise. Never a fabricated percentage.
- **Cancel** — a stop affordance calling `handle.cancel()` directly.
  The state machine's `cancelling` state renders as "Cancelling…".

The UI binds to `OperationHandle` and nothing else, exactly like the
install button does today.

### 2. Mechanism

The host already provides everything the UI needs:

```
StoreHost.enqueue(update, identity) → OperationHandle (deduped per AppIdentity)
StoreHost.activeOperations() → Stream<List<OperationHandle>> (snapshot + live)
        │
        ▼
activeOperationsProvider (app_center, keep-alive)
        │
        ├── UnifiedInstallButton: matches handle by identity, StreamBuilder on handle.state
        └── UnifiedUpdatesSection: SAME pattern (this leaf) — each _UpdateRow matches
            its identity's non-terminal handle out of the provider
```

No engine change. No backend change. `cancel()` is called on the handle;
the backends' native mechanisms (below) do the work.

### 3. Per-backend cancel semantics (verified by code inspection)

| Backend | Cancel mechanism | Interruptible | Point of no return |
|---|---|---|---|
| snap | `SnapdClient.abortChange()` (POST /v2/changes/{id} abort) | download / validate tasks | snapd change mid-`Doing` link/setup — snapd decides; handle mirrors; may resolve `Done(cancelRequested: true)` |
| deb | PackageKit D-Bus `Transaction.Cancel()` | download phase | dpkg mid-configure — finishes the unit, then honours cancel → `Done(cancelRequested: true)` |
| flatpak | SIGTERM to the spawned `flatpak(1)` child, SIGKILL after 2s grace | download (process kill) | none cleanly distinguished — kill mid-deploy is *usually* survivable (atomic OSTree layout) but nothing verifies the `cancelled ⇒ unchanged` invariant |
| appimage | cooperative flag + `throwIfCancelled()` checkpoints, partial work rolled back | between file ops | a large file copy is not interruptible mid-copy; cancel lands at the next checkpoint |

Progress payloads today: snap — determinate bytes on download, indeterminate
elsewhere. deb — download determinate but **percent-normalized**
(`bytesDone: 0–100, bytesTotal: 100`, explicitly commented in the backend,
not real bytes); applying indeterminate. flatpak — determinate when CLI
lines carry byte pairs, percent-only lines → null total; applying is a
300ms synthesized bridge with no fraction. appimage — **no numeric
progress at all** (`Preparing → Applying`, `Downloading` never emitted).

UI consequence: the cancel affordance is always enabled — every backend
has a real mechanism. Where the backend is coarse (appimage checkpoints,
flatpak kill), the UI still shows honest `cancelling` state rather than
pretending the cancel is instant. No backend currently needs the
disabled-cancel path; if one is ever added without a mechanism, the
shared widget gains a `cancelEnabled` parameter then (LLD §7).

### 4. What changes

1. **Extract** `_InFlightControls`/`_ProgressBar` from
   `widgets/unified_install_button.dart` into a public shared widget
   `widgets/operation_inflight_controls.dart` (`OperationInFlightControls`).
   The install button uses it — refactor only, behavior unchanged.
2. **Updates section**: each `_UpdateRow` matches its in-flight handle
   from `activeOperationsProvider` by `UpdateInfo.identity` and renders
   `OperationInFlightControls` while non-terminal. The update-all loop
   keeps its serial `enqueue` + `_awaitTerminal`, but rows now render
   live progress because the provider carries the handles the loop
   would otherwise drop.
3. **Tests**: fake in-flight handles (scriptable state stream) for the
   shared widget and for row-level in-flight rendering in the updates
   section; cancel dispatch; determinate vs indeterminate.

### 5. Explicitly out of scope

- No engine/host/backend/contract change. The state machine is untouched.
- No automatic update polling, no filters/sorting on the updates surface.
- No doc amendment for the 2s-terminal tension: `operation-state-machine.md`
  §3 mandates terminal-within-2s AND permits "finish the atomic unit, then
  honour the cancel". snap (async abort), deb (dpkg unit) and flatpak
  (2s SIGKILL grace) sit in that tension today. Recorded here as an honest
  gap; reconciling the authority doc is a separate slice.
- No 60s heartbeat / 10-min stall watchdog: doc-only today, no timers in
  the engine. Separate slice.

## LLD

### 6. Entities touched

| Entity | Package | Change |
|---|---|---|
| `OperationInFlightControls` | `app_center` (`lib/widgets/operation_inflight_controls.dart`) | new (extracted from install button) |
| `UnifiedInstallButton` | `app_center` (`lib/widgets/unified_install_button.dart`) | uses the shared widget; no behavior change |
| `_UpdateRow` / update-all | `app_center` (`lib/manage/unified_updates_section.dart`) | per-row in-flight match + render |
| tests | `app_center` (`test/`, flat) | `operation_inflight_controls_test.dart`, updates-section in-flight cases |

### 7. `OperationInFlightControls` — exact contract

```dart
class OperationInFlightControls extends StatelessWidget {
  const OperationInFlightControls({required this.handle, super.key});

  /// Non-terminal handle for one app. The widget subscribes to
  /// [OperationHandle.state] and renders:
  /// - Downloading with bytesTotal > 0 → determinate LinearProgressIndicator
  /// - anything else non-terminal → indeterminate LinearProgressIndicator
  /// - Cancelling → indeterminate + the cancel label's "cancelling" text
  /// Cancel button calls handle.cancel directly, always enabled (HLD §3).
  final OperationHandle handle;
}
```

- Moved verbatim from the install button's `_InFlightControls` +
  `_ProgressBar`, minus nothing: `StreamBuilder` with
  `initialData: handle.current`, `YaruIcons.stop` + `l10n.snapActionCancelLabel`.
- The `Cancelling` state renders the indeterminate bar plus a small
  "Cancelling…" caption (`l10n` key if one exists, else a plain
  localized string in `app_en.arb` — only `app_en.arb` is edited per AGENTS.md).
- No `backend_*` imports. Imports: host/contracts/wiring + flutter +
  riverpod + yaru — exactly the install button's set.

### 8. Updates section — exact contract

In `unified_updates_section.dart`, each `_UpdateRow` gains:

```dart
final ops = ref.watch(activeOperationsProvider).valueOrNull;
final handle = ops
    ?.where((h) => h.app == update.identity && !h.current.isTerminal)
    .firstOrNull;
```

- `handle != null` → row renders `OperationInFlightControls(handle: handle)`
  in the row's trailing slot (same slot that will hold the per-row update
  button; today rows have no action button).
- The update-all loop is unchanged (serial enqueue + `_awaitTerminal` +
  provider invalidation), except rows now self-render from the provider —
  no handle plumbing through the loop.
- Terminal outcomes: unchanged behavior — post-batch `ref.invalidate(
  unifiedUpdatesProvider)`; rows render from the refreshed `UpdateInfo` list.
  A `Failed` update keeps the existing per-batch error text; per-row
  failure display is out of scope (no per-row status row exists yet).

### 9. Fake in-flight handle — test contract

```dart
/// Scriptable OperationHandle for widget tests: emits the scripted states
/// on demand; cancel() records the call and emits Cancelling.
class FakeInFlightHandle extends Fake implements OperationHandle { ... }
```

- Backed by a `StreamController<OperationState>.broadcast()` (no replay —
  mirror the real contract), `current` tracked synchronously.
- Tests drive: `controller.add(Downloading(bytesDone: 3, bytesTotal: 10))`
  → determinate bar at 0.3; `Applying()` → indeterminate;
  `Cancelling()` → cancelling caption; tap stop → `cancelCalled == true`.
- Lives in `test/` flat, next to the widget tests, per AGENTS.md test
  conventions (`tearDown(resetAllServices)`).

### 10. Test matrix

`app_center`:

- `operation_inflight_controls_test.dart`:
  - determinate download (3/10) renders `LinearProgressIndicator(value: 0.3)`;
  - `Applying()` / `Downloading(bytesTotal: null)` render indeterminate;
  - `Cancelling()` renders the cancelling caption;
  - tapping stop calls `handle.cancel()` exactly once;
  - state transitions `Downloading → Applying → Done` update the bar live.
- `unified_updates_section_test.dart` (extend):
  - row with in-flight fake handle (matched via `activeOperationsProvider`
    override) renders the progress controls;
  - row without a handle renders as before;
  - update-all still enqueues in order (existing assertion preserved).
- `unified_install_button_test.dart`: unchanged assertions must pass
  against the extracted widget (refactor guard).

### 11. Rollout / risk

- Behind the existing `pages.updates.unified` flag; default off. No flag
  change in this slice.
- `dep_trace.py` must report zero new violations: the new widget and the
  section changes import host + contracts only.
- Risk: the section's `activeOperationsProvider` watch adds one more
  listener to the host stream — the provider is keep-alive and already
  watched by every install button; marginal cost nil.

### 12. Honest gaps retained

- Per-row update failure display: still batch-level error text only.
- deb download progress is percent-normalized, not real bytes — the UI
  shows it as-is (determinate), the backend owns that honesty note.
- appimage updates show indeterminate progress only (no byte counts).
- The 2s-terminal / atomic-unit tension and the missing heartbeat /
  stall watchdog stay documented-but-unimplemented (HLD §5).
