# Stall watchdog — HLD + LLD

Parent: [operation-state-machine.md](operation-state-machine.md) (authority),
[update-progress-ux.md](update-progress-ux.md).

Slice: `operation-state-machine.md` §4 specifies a 60s heartbeat / 10-min
stall watchdog, but no engine timers exist and — found by research
2026-09-27 — **no backend implements the heartbeat either**. Every backend
emits only on transport events (snapd polls, PackageKit D-Bus, flatpak
stdout, appimage body emits); long silent phases (`applying` on snap/deb,
the whole appimage copy) emit nothing. A watchdog built on "no event for
X" without backend heartbeats would murder healthy operations. So this
slice does both halves: backend heartbeats (making §4's heartbeat half
real) + engine watchdog (making the watchdog half real).

This slice also resolves the recorded tension in §3: "terminal within
2s" vs "finish the atomic unit, then honour the cancel". Decision below.

## HLD

### 1. Heartbeat — who emits

**Backends emit. The engine never synthesizes liveness.** An engine-side
re-emit would prove the engine is alive, not the backend — theater, not
honesty. The heartbeat is a backend self-transition: re-emit the current
`downloading`/`applying` state (same payload) when silent for 60s.
Self-transitions for progress updates are legal per the DAG.

Shared helper, `store_contracts`:

```dart
class PhaseHeartbeat {
  PhaseHeartbeat({this.interval = const Duration(seconds: 60),
                  DateTime Function()? clock});
  void markEmitted();            // call on EVERY state emission
  bool shouldBeat(OperationState state);  // true only for downloading/
                                         // applying silent >= interval
}
```

Wiring per backend (per-backend realities):

| Backend | Tick source | Notes |
|---|---|---|
| snap | existing 500ms `getChange` poll loop | No new timer. Each tick: `if (_heartbeat.shouldBeat(current)) _emitState(current)` |
| deb | `Timer.periodic(60s)` during downloading/applying | Event-driven otherwise; timer cancelled on phase change/terminal |
| flatpak | `Timer.periodic(60s)` during downloading/applying | stdout-driven otherwise; same lifecycle |
| appimage | `Timer.periodic(60s)` during downloading/applying | Body-driven; appimage install is `Preparing → Applying`, heartbeat covers the silent copy+hash |

The 60s interval is hardcoded (contract §4). Tests use an injectable
clock on `PhaseHeartbeat` — the 60s production tick itself is
inspection-verified, not exam-verified (the exam cannot wait 60s;
documented as an honest gap).

### 2. Watchdog — the engine watches

Lives in `StoreHost` (`store_host`), which wraps every enqueued handle in
a `_StallWatchedHandle implements OperationHandle, StallAware`:

```
backend.install/remove/update → inner handle
        │
StoreHost.enqueue wraps → _StallWatchedHandle
        │  - forwards inner.state events; every event re-arms the stall timer
        │  - StallAware.isStalled: advisory flag, surfaced to UI
        ▼
UI binds to the wrapper (same OperationHandle type, same provider path)
```

**Stall definition:** no state event for `engine.stall_timeout`
(flag-controlled, default **10 min** — see §5) while in a watched phase.

**Watched phases:** `restoring`, `preparing`, `downloading`, `verifying`,
`applying`. **Excluded:** `queued` (engine-owned wait, not backend work),
`authenticating` (user-attended polkit prompt — the user may legitimately
take 10 min), `cancelling` (governed by §3-amended below, not by the
stall timer).

**Watchdog action** (doc §4, made real):

1. Timer fires → set `isStalled = true` (advisory; UI shows "Stalled"),
   call `inner.cancel()`.
2. 30s grace: if the backend reaches a terminal state, forward it
   (normal path — `Cancelled`, or `Done(cancelRequested: true)`).
3. No terminal within 30s → the wrapper emits
   `Failed(TimeoutException(debugDetail: …, stalledPhase: '<Phase>'))`
   on its own stream and detaches. The backend may still be running
   underneath; the engine no longer reports it. (`TimeoutException`
   already carries `stalledPhase`; remediation is `retry`.)

**Testable clock:** no `DateTime.now()` in the engine. `StoreHost` takes
an optional `TimerFactory`:

```dart
typedef TimerFactory = Timer Function(Duration, void Function());
```

Production passes a factory returning real `Timer`s; tests pass a fake
returning scriptable timers with manual `advance()`. No real-time sleeps
in tests. (Only the delay *scheduling* is abstracted — no wall-clock
reads are needed at all: every event re-arms a fresh single-shot timer.)

**`StallAware`** (new, `store_contracts`, additive — backends untouched):

```dart
abstract class StallAware {
  bool get isStalled;
  Stream<bool> get stalledChanges;
}
```

UI (`OperationInFlightControls`): if `handle is StallAware && stalled`
and current is not `Cancelling`, render the "Stalled" caption
(new `app_en.arb` key only). The `Cancelling` → terminal path already
renders via the existing widget. No `backend_*` imports.

### 3. The 2s-terminal tension — DECIDED

Old §3 said both "MUST reach a terminal state within 2s of `cancel()`"
and "if the backend cannot interrupt the current atomic unit, it finishes
the unit, then honours the cancel". A dpkg configure or a large file copy
can exceed 2s — the two sentences contradict.

**New rule:** the backend MUST emit `cancelling` within 2s of `cancel()`
(prompt acknowledgment) and MUST NOT start new work afterwards. The
terminal state follows as soon as the in-flight atomic unit completes.
All four backends already emit `Cancelling` (verified 2026-09-27); the
contract exam is amended to assert it (previously asserted terminal-only).

Exam (fixtures stay fast — the 5s fixture bound remains as a
hung-backend tripwire; production's bound is the atomic unit's natural
length, stated honestly in the doc).

### 4. What changes

| Entity | Package | Change |
|---|---|---|
| `PhaseHeartbeat` | `store_contracts` | new; injectable clock; unit-tested |
| `StallAware` | `store_contracts` | new interface; no backend changes |
| exam assertion 3 | `store_contracts` | assert `Cancelling` emitted ≤2s after cancel(); keep ≤5s-to-terminal on fixtures |
| `OperationHandle.cancel()` doc | `store_contracts` | 2s-ack wording |
| 4 backend handles | `backend_*` | heartbeat wiring (§1 table); ~10 lines each |
| `StoreHost` | `store_host` | `TimerFactory` param; `_StallWatchedHandle`; flag default fix (§5) |
| `OperationInFlightControls` | `app_center` | stalled caption; one `app_en.arb` key |
| `operation-state-machine.md` | docs | §3 + §4 + §11 amendments (this slice) |

### 5. Flag default alignment

`MapFeatureFlags._defaults` has `engine.stall_timeout_ms: 30000`, but
§4 says default 10 min — and nothing has ever read the flag. A 30s
watchdog would false-positive against the 60s heartbeat (a healthy
backend may legitimately go 60s silent). **Default becomes 600000.**
Safe: the flag was never consumed.

### 6. Explicitly out of scope

- No change to the state DAG. No new `OperationState`. `StallAware` is a
  side interface, not a state.
- No auto-retry after `TimeoutException` — remediation is `retry`,
  the user decides.
- No watchdog for user-initiated cancels stuck in `cancelling`
  (contract violation; exam-guarded on fixtures).
- Heartbeat *timing* (the 60s tick) is inspection-verified, not
  exam-verified — honest gap, stated here.

## LLD

### 7. `PhaseHeartbeat` — exact contract

```dart
class PhaseHeartbeat {
  PhaseHeartbeat({
    this.interval = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration interval;

  /// Record that a state event was emitted. Backends call this on every
  /// emission (including the phase-entering one).
  void markEmitted();

  /// True when [state] is downloading/applying AND no emission for
  /// >= interval. False for every other phase (queued/authenticating/
  /// preparing/verifying/cancelling/terminal never heartbeat).
  bool shouldBeat(OperationState state);
}
```

Unit tests (fake clock): silent 59s → false; 60s → true; `markEmitted`
resets; `Preparing` at +1h → false; terminal → false.

### 8. Backend wiring pattern

snap (`handle.dart`, in the poll loop after `_emitState` decisions):

```dart
_heartbeat.markEmitted(); // wherever a state is emitted
// …in the tick:
if (_heartbeat.shouldBeat(current)) _emitState(current);
```

deb/flatpak/appimage: start `Timer.periodic(60s)` on first
downloading/applying emission; tick does
`if (_heartbeat.shouldBeat(current)) emit(current)`; cancel on terminal.
`markEmitted()` on every emission path.

Re-emitting the identical state object is a legal self-transition;
`bytesDone`/`fraction` unchanged satisfies monotonicity.

### 9. `_StallWatchedHandle` — exact contract (`store_host`)

```dart
class _StallWatchedHandle implements OperationHandle, StallAware {
  _StallWatchedHandle(
    OperationHandle inner, {
    required Duration stallTimeout,
    required TimerFactory timers,
  });

  // OperationHandle: id/app/kind/current/cancel() delegate to inner.
  // state: broadcast; forwards inner events; synthesizes the terminal
  //   Failed(TimeoutException) when the grace expires.
  // StallAware: isStalled + stalledChanges (broadcast, no replay).
}
```

State machine of the wrapper:

- inner event, not terminal → forward; re-arm single-shot stall timer
  iff phase is watched (drop `queued`/`authenticating`/`cancelling`).
- inner event, terminal → forward; disarm everything; mark completed.
- stall timer fires → `isStalled = true` (+ `stalledChanges.add(true)`);
  `inner.cancel()`; start 30s single-shot grace timer.
- grace fires, still no terminal → emit
  `Failed(TimeoutException(debugDetail: 'operation stalled in <Phase>; '
  'watchdog cancelled and the backend did not terminate within 30s',
  stalledPhase: '<Phase>'))`; disarm; ignore all later inner events
  ("Terminal states emit no further events. Ever.").
- `cancel()` → `inner.cancel()` (watchdog timers keep running; a
  user cancel races the watchdog honestly — whichever terminal wins).

`StoreHost.enqueue` stores and returns the wrapper; `_watchTerminal`
and `activeOperations()` are unchanged (they already go through the
stored handle). `stallTimeout` = `flags.getInt('engine.stall_timeout_ms')`
ms, default 600000.

### 10. Test matrix

`store_contracts`: `PhaseHeartbeat` unit tests (fake clock, §7 cases).

`store_host` (fake `TimerFactory` with manual `advance`):

- no events for stallTimeout in `applying` → `isStalled == true`,
  `inner.cancel` called.
- event at stallTimeout − 1s re-arms (advance past original deadline →
  no stall).
- terminal event disarms (advance 2× timeout → still not stalled).
- `queued` / `authenticating` never arm the timer.
- watchdog cancel → backend emits `Cancelling` then `Cancelled` →
  forwarded, no synthetic failure, `isStalled` stays true (advisory).
- watchdog cancel → 30s grace, no terminal → synthetic
  `Failed(TimeoutException)` with `stalledPhase == 'Applying'`; later
  inner terminal ignored.
- user `cancel()` delegates to inner.

`app_center`: stalled caption renders for `StallAware`+stalled fake;
not rendered otherwise; existing control tests unchanged.

Exam: amended assertion 3 runs against all four backends' existing
exam suites (must stay green).

### 11. Rollout / risk

- No flag flip: watchdog is engine-always-on, but stallTimeout 10 min
  means it only fires on genuine hangs. Heartbeat adds one state
  re-emit per 60s of silence per operation — negligible traffic; the
  UI already handles repeat `downloading` events (progress updates).
- `dep_trace.py`: `StallAware` lives in `store_contracts` — UI imports
  stay within the sanctioned boundary.
- Risk: a backend whose 60s tick throws must not break the operation —
  tick bodies are guarded (try/catch, heartbeat is best-effort).
