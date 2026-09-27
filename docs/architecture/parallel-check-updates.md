# Parallel checkUpdates with per-backend timeouts — HLD + LLD

Parent: [update-polling.md](update-polling.md) (§2 out-of-scope item, §9
honest limitation — this slice closes that recorded gap),
[host-wiring.md](host-wiring.md), [operation-state-machine.md](operation-state-machine.md)
(§7 error taxonomy).

Today `StoreHost.checkUpdates()` is sequential: `await b.checkUpdates()`
in a loop with try/catch. A throwing backend degrades to partial, but a
**hung** backend stalls the whole check forever — the Updates page, the
nav badge, and the `UpdatePollScheduler` all wait on it. `search()`
already solved this exact problem (parallel fan-out, per-backend
`.timeout()`, `onError → finishOne` = partial). This slice applies the
same treatment to `checkUpdates()`.

## HLD

### 1. Fan-out design — mirror `search()`, adapted to futures

`search()` streams; `checkUpdates()` returns one list per backend, so
the shape is `Future.wait`, not streams:

```dart
Future<CheckUpdatesResult> checkUpdatesDetailed() async {
  final timeout = _checkUpdatesTimeout();          // flag, read per call
  final backends = await enabledBackends();
  final slots = List<_Slot?>.filled(backends.length, null);
  await Future.wait([
    for (var i = 0; i < backends.length; i++)
      _checkOne(backends[i], timeout).then((r) => slots[i] = r),
  ]);
  final updates = <UpdateInfo>[];
  final partial = <String>[];
  for (var i = 0; i < backends.length; i++) {
    final s = slots[i];
    if (s == null) { partial.add(backends[i].id); continue; }
    updates.addAll(s);
  }
  return CheckUpdatesResult(updates: updates, partialBackendIds: partial);
}
```

Per-backend task `_checkOne(backend, timeout)`:

1. Wrap `isAvailable()` + `backend.checkUpdates()` in one closure — the
   timeout budget covers **both**. `isAvailable()` is exam-guarded at
   <200ms (operation-state-machine.md §11.10), but a contract-violating
   hang there stalls the fan-out identically; covering it costs nothing.
2. Race the closure against a timer from the host's injectable
   `TimerFactory` (same seam as the stall watchdog — §6 for why, not
   `Future.timeout`).
3. Outcome: `List<UpdateInfo>` on success, `null` on any failure
   (timeout, throw). The orphan future keeps running underneath; it is
   awaited with an error-absorbing listener so it can never surface an
   unhandled async error. Timeout aborts the **wait**, not the work —
   a backend that returns late gets its results dropped (same detach
   semantics as the watchdog: the engine no longer reports it).

`checkUpdates()` (the `UnifiedCatalog` override) keeps its signature
and behavior contract: `return (await checkUpdatesDetailed()).updates;`
— silent partial degradation, never throws. Zero breaking change to
`StoreBackend` or `UnifiedCatalog`.

### 2. Timeout flag — DECIDED: new `updates.backend_timeout_ms`

| Candidate | Verdict | Reason |
|---|---|---|
| `catalog.search_timeout_ms` (5s) | Rejected | Interactive search wants fast partial; update checks hit package-metadata CLIs (snapd refresh list, PackageKit) that legitimately take 10–30s on slow systems. 5s would false-positive on healthy backends every poll tick. |
| `engine.stall_timeout_ms` (10min) | Rejected | Budgets in-flight *operations*, not read queries. A 10-min budget means a hung backend pins the Updates page/badge for 10 min and blocks the scheduler's coalescing window — this slice exists to kill exactly that stall. |
| **New `updates.backend_timeout_ms`, default 30000 (30s)** | **Chosen** | Namespaced with the updates surface (`updates.poll_interval_ms`), independent of search and op-watchdog budgets. 30s >> healthy metadata-fetch time, << poll interval (6h) and user patience on manual refresh. |

Flag contract (flags.dart `_defaults`, ADR-010 owner + removal date):

```dart
'updates.backend_timeout_ms': 30000, // 30s per-backend check budget.
                                     // Owner: libreapp-center.
                                     // Removal date: 2027-06-30 (ADR-010).
```

- Read **at call time** inside `checkUpdatesDetailed()` — never cached.
  Tests mutate `MapFeatureFlags` between calls to prove it.
- Non-positive value → fall back to the 30000 default, **never disabled**.
  A timeout is a safety bound, not a feature: disabling it reintroduces
  the exact hang this slice kills (mirrors `search()`'s `> 0 ? v : 5000`
  fallback).
- Only consumed when `pages.updates.unified` is true (flag off → legacy
  path, host method unused) — same gating as `updates.poll_interval_ms`.

### 3. Partiality surfacing — DECIDED: additive `checkUpdatesDetailed()`

Chosen: **(a)** — `Future<CheckUpdatesResult> checkUpdatesDetailed()`
on `StoreHost` as a **host convenience**, mirroring `getDetails()` (host
method, not on `UnifiedCatalog`, not on `StoreBackend`). Rejected (b)
(`lastCheckPartial` getter/stream on the host) because partiality would
ride out-of-band from the data: concurrent callers race, and the
provider path is functional (`ref.watch` returns a value, no host state
read afterwards) — a side-channel getter doesn't fit it.

```dart
/// in store_host (new file, exported): the detailed update-check result.
class CheckUpdatesResult {
  final List<UpdateInfo> updates;        // what the backends reported
  final List<String> partialBackendIds; // backends excluded (hung/threw)
  bool get isPartial => partialBackendIds.isNotEmpty;
}
```

Provider wiring (app_center, no contract change):

- `unifiedUpdatesResultProvider` (new `FutureProvider<CheckUpdatesResult>`)
  → `host.checkUpdatesDetailed()`.
- `unifiedUpdatesProvider` keeps its type and contract
  (`FutureProvider<List<UpdateInfo>>`), reimplemented as a projection:
  `(await ref.watch(unifiedUpdatesResultProvider.future)).updates` —
  **one fetch, shared future** (watching the result provider's `.future`
  joins its in-flight fetch; no double `checkUpdates()`).
- UI surfacing: `UnifiedUpdatesSection` watches
  `unifiedUpdatesResultProvider`; when `isPartial`, renders a quiet
  caption under the header ("Some sources didn't respond — showing
  partial results", one new `app_en.arb` key). No modal, no error state,
  badge keeps `updates.length` (byte-compatible with today). The
  section's existing error path is untouched — the host still never
  throws.
- Legacy flag-off path: untouched (never calls the new method).

Why not make `checkUpdates()` itself return the result: `UnifiedCatalog`
promises `Future<List<UpdateInfo>>`; changing it breaks every
`UnifiedCatalog` implementer. The additive host method keeps the
contract surface frozen.

### 4. Error classification — same handling, typed logs

All three failure classes → **exclude the backend, mark partial,
keep going**. Classification differs only in logs/telemetry:

| Class | Detection | Log taxonomy |
|---|---|---|
| **Timeout** | timer fires before the closure completes | `backendId`, classification `timeout`, budget ms |
| **Typed `StoreException`** | closure throws a `StoreException` | `backendId`, classification `typed`, the exception's `code` (operation-state-machine.md §7: `network`, `backend_unavailable`, …). Telemetry counts by `code`, never message text. |
| **Unexpected** | closure throws anything else | `backendId`, classification `unknown`, wrapped as `UnknownStoreException` in the debug log only (bug-report generator, per §7 — never shown to the user). Note: throwing raw already fails the contract exam; the host catches regardless. |

Timeouts are **not** converted into `TimeoutException` here — no
exception escapes at all. The taxonomy's `TimeoutException`/`retry`
remediation belongs to *operations* (watchdog path); a partial update
check's remediation is "wait for the next tick", which the scheduler
does automatically.

### 5. Ordering / dedup guarantees

The contract promises **nothing** about ordering (`UnifiedCatalog`
and `StoreBackend` docs are silent; the UI renders list order, no
client-side sort in `UnifiedUpdatesSection`). Today's implementation
happens to return backend registration order. This slice **preserves
that**: results are indexed into `slots` by backend position and
reassembled in registration order — completion order is
nondeterministic and must never leak into the list. Byte-deterministic
vs today when all backends are healthy.

Dedup: unchanged thesis — duplicates beat unsafe merges (update-polling.md
§2). One `UpdateInfo` per backend report, concatenated. A hung backend's
updates simply don't appear this tick.

### 6. Poll-scheduler interaction — no special-casing

A tick: scheduler → invalidate → provider → `checkUpdatesDetailed()`.

- Partial tick → badge shows what arrived, section shows the quiet
  caption. No error UI (scheduler stays silent, per update-polling.md
  §2 "Failure posture").
- Next tick (interval / resume / manual pull-to-refresh) retries **all**
  enabled backends, hung one included — the hung backend's updates
  reappear when it recovers. Self-healing, no retry list to maintain.
- Scheduler coalescing (skip tick while provider is in-flight) is
  unchanged and now actually effective: with a 30s per-backend bound,
  a tick can never overlap the next one by more than the timeout plus
  the slowest healthy backend.
- Update-all on a partial list updates only what is listed — the
  caption says why other backends' updates may be missing. Honest, no
  extra guard needed.

## LLD

### 7. Entities touched

| Entity | Package | Change |
|---|---|---|
| `MapFeatureFlags._defaults` | `store_host` (`flags.dart`) | + `updates.backend_timeout_ms: 30000` (ADR-010 owner/removal-date comment) |
| `CheckUpdatesResult` | `store_host` (new `lib/src/check_updates_result.dart`, exported) | `{updates, partialBackendIds, isPartial}` — plain data class, no freezed needed (two fields + derived getter) |
| `StoreHost.checkUpdatesDetailed()` | `store_host` (`host.dart`) | fan-out implementation (§1); flag read per call |
| `StoreHost._checkOneWithTimeout` | `store_host` (`host.dart`, private) | TimerFactory-raced per-backend task; returns `List<UpdateInfo>?` (`null` = excluded) |
| `StoreHost.checkUpdates()` | `store_host` (`host.dart`) | becomes `(await checkUpdatesDetailed()).updates` |
| `unifiedUpdatesResultProvider` | `app_center` (`lib/manage/unified_updates_provider.dart`) | new `FutureProvider<CheckUpdatesResult>` |
| `unifiedUpdatesProvider` | same file | reimplemented as projection over the result provider (type unchanged) |
| `UnifiedUpdatesSection` | `app_center` | quiet partial caption (one new `app_en.arb` key); watches the result provider |
| `update-polling.md` | docs | §2/§9: close the recorded gap (this slice) |

No `store_contracts` changes. No `StoreBackend` changes. No exam changes.

### 8. Test seam — DECIDED: race via the existing `TimerFactory`

`Future.timeout(duration)` schedules with real wall-clock timers (zone
timers, not injectable) — tests would need real sleeps or `fake_async`.
The host already injects `TimerFactory` for the watchdog; reuse it:

```dart
Future<List<UpdateInfo>?> _checkOneWithTimeout(
    StoreBackend backend, Duration timeout) {
  final done = Completer<List<UpdateInfo>?>();
  Timer? timer;
  // Absorb the orphan: a backend that finishes late must never surface
  // an unhandled async error after we stopped waiting.
  unawaited(() async {
    try {
      final available = await backend.isAvailable();
      final updates = available ? await backend.checkUpdates() : <UpdateInfo>[];
      if (!done.isCompleted) {
        timer?.cancel();
        done.complete(updates);
      }
    } catch (_) {
      if (!done.isCompleted) {
        timer?.cancel();
        done.complete(null); // typed or raw — classification in logs only
      }
    }
  }());
  timer = _timerFactory(timeout, () {
    if (!done.isCompleted) done.complete(null); // budget exceeded
  });
  return done.future;
}
```

(Production shape; the leaf writes it, with log lines per the §4 taxonomy.)

- Fake `TimerFactory` with manual `advance()` (same harness as
  `stall_watchdog_test.dart`): a backend whose future never completes
  → `advance(30s)` fires the timeout → partial. No real-time sleeps.
- Timeout is **one shot per backend per call**, read from the flag at
  call time; `MapFeatureFlags.setFlag` between calls changes the next
  call's budget (test asserts both).

### 9. Test matrix

`store_host` (fake `TimerFactory`, fake backends via
`test/stub_backends.dart` + a hanging fake):

1. One backend hangs → others' updates returned, `partialBackendIds ==
   ['hung']`, `checkUpdates()` returns the partial list, host never
   throws. Fake time only.
2. All hang → `[]` + all ids partial.
3. Backend throws `NetworkException` → excluded + partial; no throw.
4. Backend throws raw `StateError` → excluded + partial; no throw
   (log classification `unknown`).
5. Flag-driven budget: seed `updates.backend_timeout_ms: 100`; fake
   backend completing at fake-101ms → partial; completing at 99ms →
   full. Then `setFlag` to 1000, repeat → full. (Budget read per call.)
6. `updates.backend_timeout_ms <= 0` → default 30000 applies
   (fallback, never disabled).
7. Registration-order preservation: backend B (slow) completes after
   backend A (fast) → updates ordered A-then-B.
8. Hanging `isAvailable()` (never completes) → backend excluded via
   the same budget, no stall of the fan-out.
9. Orphan absorption: hung backend completes *after* the timeout →
   result dropped, no unhandled async error (test via
   `runZonedGuarded` or completing the late future then pumping).

`app_center`:

- `unifiedUpdatesProvider` projects `.updates` (existing tests byte-green).
- Partial caption renders when `partialBackendIds` non-empty; absent otherwise.
- Single fetch: fake host counts `checkUpdatesDetailed()` calls == 1
  when both providers are watched.

### 10. Rollout / risk

- Flag-gated by `pages.updates.unified` (default false): zero behavior
  change for existing users; the new path only runs on the unified
  updates surface.
- Worst-case check latency is now bounded: `max(healthy backends) + 30s`,
  vs today's unbounded. Poll-tick worst case is known and constant.
- `dep_trace.py`: `CheckUpdatesResult` lives in `store_host` — UI
  imports stay within the sanctioned boundary (same as `UnifiedApp`).
- Risk: a backend whose `checkUpdates()` resolves *after* timeout keeps
  its CLI call running underneath (can't be cancelled through the
  contract). Bounded by one orphan per backend per tick; next tick
  supersedes. Same honesty model as the watchdog detach.

## 11. Honest limitations

- **Timeout aborts the wait, not the work.** `StoreBackend` has no
  cancel-checkUpdates; an orphaned CLI call runs to completion in the
  background. If backends pile up orphans faster than they die, memory
  grows — acceptable at ≤1 orphan/backend/tick on a 6h interval, but
  stated.
- **No heartbeat/progress during checks.** A backend that is *slow but
  alive* (30s+ of real metadata fetching on a loaded system) gets cut
  and marked partial exactly like a dead one. The 30s default is the
  mitigation; per-backend tuning is a future flag, not this slice.
- **Partiality is per-tick, not persisted.** The caption disappears on
  the next successful full check; there is no "backend X is flapping"
  history. Flap detection would need a new entity — out of scope.
- **`installed()` and `search()`'s availability path are untouched.**
  `installed()` is still sequential-with-catch (same hang exposure,
  different slice if it bites); only `checkUpdates()` gets the fan-out
  here.

## 12. Implementation notes (deviations from the sketch above)

- **`checkUpdatesDetailed()` does not call `enabledBackends()`.**
  The §1 sketch does, but this slice's own test 8 requires a hanging
  `isAvailable()` to be absorbed by the per-backend budget — and
  `enabledBackends()` runs a sequential `isAvailable()` loop with no
  timeout before the fan-out even starts. Instead the method filters
  by the `backend.<id>.enabled` flag synchronously and runs
  `isAvailable()` *inside* the budgeted closure. Behavior for healthy
  backends is identical (flag-off or throwing-availability backends
  are still excluded); the fan-out just can't be stalled before it
  begins.
- **No log lines per the §4 taxonomy.** `store_host` is a pure-Dart
  package depending only on `store_contracts` — it owns no logging
  sink, and adding a logging dependency is out of scope. The
  classification is structural: timeout, typed `StoreException`, and
  raw throw are caught at separate points in `_checkOneWithTimeout`
  and excluded identically, exactly as §4 requires; only the log
  metadata is missing. If a host log sink ever lands, wire the
  taxonomy there.
