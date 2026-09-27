# Parallel installed() with per-backend timeouts — HLD + LLD

Parent: [parallel-check-updates.md](parallel-check-updates.md) (same
fan-out treatment applied to `checkUpdates()`; §11 recorded this slice),
[host-wiring.md](host-wiring.md), [update-polling.md](update-polling.md)
(§9 honest limitation — `checkUpdates()` sequential, now closed; this
slice closes the `installed()` twin).

Today `StoreHost.installed()` is sequential: `await b.listInstalled()`
in a loop with try/catch. A throwing backend degrades to partial, but a
**hung** backend stalls the whole installed listing — the unified
Manage page, its pull-to-refresh, and the post-operation auto-refetch
all wait on it. This slice applies the checkUpdates treatment to
`installed()`.

## HLD

### 1. Fan-out design — mirror checkUpdatesDetailed(), adapted to UnifiedApp assembly

```dart
Future<InstalledResult> installedDetailed() async {
  final timeoutMs = _flags.getInt('installed.backend_timeout_ms');
  final timeout = Duration(milliseconds: timeoutMs > 0 ? timeoutMs : 30000);
  final backends = [
    for (final b in _backends)
      if (_flags.isEnabled('backend.${b.id}.enabled')) b,
  ];
  // Index slots preserve registration order, exactly like
  // checkUpdatesDetailed(): completion order is nondeterministic and
  // must never leak into the result list.
  final slots = List<List<AppInfo>?>.filled(backends.length, null);
  await Future.wait([
    for (var i = 0; i < backends.length; i++)
      _installedOneWithTimeout(backends[i], timeout).then((r) => slots[i] = r),
  ]);
  final apps = <UnifiedApp>[];
  final partial = <String>[];
  for (var i = 0; i < backends.length; i++) {
    final slot = slots[i];
    if (slot == null) {
      partial.add(backends[i].id);
      continue;
    }
    for (final app in slot) {
      // v1 grouping policy: one UnifiedApp per AppInfo, no
      // cross-backend merging (same as search()/installed() today).
      apps.add(
        UnifiedApp(
          groupId: '${backends[i].id}:${app.identity.nativeId}',
          variants: [app],
        ),
      );
    }
  }
  return InstalledResult(apps: apps, partialBackendIds: partial);
}
```

`installed()` (the `UnifiedCatalog` override) keeps its signature and
never-throws contract: `return (await installedDetailed()).apps;`.

**Refactor note:** `_checkOneWithTimeout` and
`_installedOneWithTimeout` share the same race skeleton
(isAvailable() + fetch inside the budget, orphan absorption, null =
excluded). This slice extracts the generic private helper
`_raceOne<T>(StoreBackend, Duration, Future<List<T>> Function(StoreBackend))`
and reimplements both one-backend methods on it — one race
implementation, behavior-preserving for checkUpdates (existing tests
stay green byte-for-byte).

Same deviation as the checkUpdates slice (§12 there):
`enabledBackends()` is NOT used — the flag filter runs synchronously
and `isAvailable()` runs INSIDE the per-backend budget, so a
contract-violating hang in `isAvailable()` can't stall the fan-out
before it starts.

### 2. Timeout flag — DECIDED: new `installed.backend_timeout_ms`

| Candidate | Verdict | Reason |
|---|---|---|
| Reuse `updates.backend_timeout_ms` (30s) | Rejected | Couples the Manage page surface to the updates surface. The checkUpdates slice deliberately namespaced the budget per surface (`updates.`); installed listing hits different CLIs (snapd `/v2/snaps`, PackageKit `GetPackages`) with different latency profiles, and an ops team tuning one surface must not silently retune the other. |
| Reuse `engine.stall_timeout_ms` (10min) | Rejected | Budgets in-flight *operations*, not read queries — same rejection as the checkUpdates slice. |
| **New `installed.backend_timeout_ms`, default 30000 (30s)** | **Chosen** | Surface-namespaced, independent of updates/search/op-watchdog budgets. Read at call time, never cached; `<= 0` falls back to the default, never disables (a timeout is a safety bound, not a feature). |

Flag contract (flags.dart `_defaults`, ADR-010 owner + removal date):

```dart
'installed.backend_timeout_ms': 30000, // Per-backend budget for the
    // installed listing (docs/architecture/parallel-installed.md §2).
    // Covers isAvailable() + listInstalled() per backend in the
    // installedDetailed() fan-out. <= 0 falls back to this default,
    // never disables. Read at call time, never cached.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
```

Only consumed when `pages.manage.unified` is true (flag off → legacy
path, host method unused) — same gating shape as
`updates.backend_timeout_ms`.

### 3. Partiality surfacing — DECIDED: additive `installedDetailed()`

Chosen: **(a)** — `Future<InstalledResult> installedDetailed()` on
`StoreHost` as a host convenience, mirroring `checkUpdatesDetailed()`.
Same rejection of the side-channel getter (concurrent callers race;
the provider path is functional). No `UnifiedCatalog` change, no
`StoreBackend` change.

```dart
/// in store_host (new file lib/src/installed_result.dart, exported):
/// the detailed installed-listing result.
class InstalledResult {
  final List<UnifiedApp> apps;          // one card per AppInfo, registration order
  final List<String> partialBackendIds; // backends excluded (hung/threw)
  bool get isPartial => partialBackendIds.isNotEmpty;
}
```

Provider wiring (app_center, no contract change):

- `unifiedInstalledResultProvider` (new `FutureProvider<InstalledResult>`,
  `ref.keepAlive()` — it owns the fetch and the stale-while-revalidate
  contract the polish slice built) → `host.installedDetailed()`.
- `unifiedInstalledProvider` keeps its type and contract
  (`FutureProvider<List<UnifiedApp>>`), reimplemented as a projection:
  `(await ref.watch(unifiedInstalledResultProvider.future)).apps` —
  one fetch, shared future, no double `listInstalled()`.
- **Invalidation moves to the result provider.** Every site that today
  calls `ref.invalidate(unifiedInstalledProvider)` (pull-to-refresh,
  post-terminal-operation auto-refetch, retry) must invalidate
  `unifiedInstalledResultProvider` instead — invalidating the
  projection alone would re-run the projection against the result
  provider's cached value and NOT refetch. (This mirrors the updates
  surface: everything invalidates `unifiedUpdatesResultProvider`.)
- `unifiedManageVisibleAppsProvider` (filter/sort) keeps watching the
  projection — unchanged.
- UI surfacing: `UnifiedManagePage` watches
  `unifiedInstalledResultProvider`; when `isPartial`, renders the same
  quiet caption the updates section uses ("Some sources didn't respond
  — showing partial results"; reuse the existing `app_en.arb` key from
  the updates slice, no new strings). No modal, no error state. The
  page's existing error path is untouched — the host still never
  throws.
- Legacy flag-off path: untouched (never calls the new method).

### 4. Error classification — same handling as checkUpdates

Timeout, typed `StoreException`, raw throw → **exclude the backend,
mark partial, keep going**. Classification differs only in
logs/telemetry; `store_host` owns no log sink, so no log lines
(same as parallel-check-updates.md §12). Timeouts are not converted
into exceptions — nothing escapes.

### 5. Ordering / dedup guarantees

- **Registration order preserved**: results indexed into slots by
  backend position, reassembled in order. Byte-deterministic vs today
  when all backends are healthy.
- **No cross-backend merging** (v1 grouping policy, unchanged): one
  `UnifiedApp` per `AppInfo`, `groupId = backendId:nativeId`.
- A hung backend's apps simply don't appear this tick; the next fetch
  retries every enabled backend (self-healing, same as checkUpdates).

### 6. Refresh interaction — no special-casing

Pull-to-refresh / terminal-operation refetch invalidate the result
provider → `installedDetailed()` re-runs → all backends retried. The
500ms debounce and invalidate-while-loading guard from the polish
slice are unchanged. A hung backend no longer pins the refresh: worst
case is `max(healthy backends) + 30s`.

## LLD

### 7. Entities touched

| Entity | Package | Change |
|---|---|---|
| `MapFeatureFlags._defaults` | `store_host` (`flags.dart`) | + `installed.backend_timeout_ms: 30000` (ADR-010 owner/removal-date comment) |
| `InstalledResult` | `store_host` (new `lib/src/installed_result.dart`, exported from `store_host.dart`) | `{apps, partialBackendIds, isPartial}` — plain data class, mirrors `CheckUpdatesResult` |
| `StoreHost.installedDetailed()` | `store_host` (`host.dart`) | fan-out implementation (§1); flag read per call |
| `StoreHost._raceOne<T>` | `store_host` (`host.dart`, private) | generic race helper extracted from `_checkOneWithTimeout` |
| `StoreHost.installed()` | `store_host` (`host.dart`) | becomes `(await installedDetailed()).apps` |
| `StoreHost.checkUpdatesDetailed()` | `store_host` (`host.dart`) | reimplemented on `_raceOne` — behavior-preserving (existing tests stay green) |
| `unifiedInstalledResultProvider` | `app_center` (`lib/manage/unified_installed_provider.dart`) | new `FutureProvider<InstalledResult>`, `ref.keepAlive()` |
| `unifiedInstalledProvider` | same file | reimplemented as projection over the result provider (type unchanged) |
| `UnifiedManagePage` | `app_center` | all `invalidate(unifiedInstalledProvider)` → `invalidate(unifiedInstalledResultProvider)`; quiet partial caption from the result provider |
| `parallel-check-updates.md` | docs | §11: close the recorded gap (this slice) |

No `store_contracts` changes. No `StoreBackend` changes. No exam changes.

### 8. Test seam — reuse the existing `TimerFactory`

Same race as `_checkOneWithTimeout` (never `Future.timeout`):
fake `TimerFactory` with manual `advance()`, zero real-time sleeps,
orphan absorption (late backend results dropped, errors absorbed).

### 9. Test matrix

`store_host` (new `test/parallel_installed_test.dart`; fake
`TimerFactory`, fake backends via `test/stub_backends.dart` + a
hanging fake — copy the harness shape from
`check_updates_test.dart`, do NOT import across test files):

1. One backend hangs → others' apps returned, `partialBackendIds ==
   ['hung']`, `installed()` returns the partial list, host never
   throws. Fake time only.
2. All hang → `[]` + all ids partial.
3. Backend throws typed `BackendUnavailableException` in
   `listInstalled()` → excluded + partial; no throw.
4. Backend throws raw `StateError` → excluded + partial; no throw.
5. Flag-driven budget: seed `installed.backend_timeout_ms: 100`; fake
   backend completing at fake-101ms → partial; completing at 99ms →
   full. Then `setFlag` to 1000, repeat → full. (Budget read per call.)
6. `installed.backend_timeout_ms <= 0` → default 30000 applies
   (fallback, never disabled).
7. Registration-order preservation under shuffled completion: backends
   A/B/C complete in order C, A, B → apps ordered A-then-B-then-C
   (groupId prefix order).
8. Merge semantics unchanged: two backends reporting the same nativeId
   produce two cards (`snap:x`, `deb:x`) — no cross-backend dedup.
9. Hanging `isAvailable()` (never completes) → backend excluded via
   the same budget, no stall of the fan-out.
10. Orphan absorption: hung backend completes *after* the timeout →
    result dropped, no unhandled async error.
11. `checkUpdatesDetailed()` regression: the `_raceOne` refactor keeps
    all existing `check_updates_test.dart` tests green (run, don't
    rewrite).

`app_center`:

- `unifiedInstalledProvider` projects `.apps` (existing tests
  byte-green where behavior is unchanged).
- Invalidating `unifiedInstalledResultProvider` triggers exactly one
  fresh `installedDetailed()`; invalidating the projection alone does
  NOT refetch (documents the invalidation contract — assert the fetch
  count stays 1).
- Partial caption renders when `partialBackendIds` non-empty; absent
  otherwise.
- Filter/sort providers still operate over the projection's list
  (existing manage-polish tests stay green).

### 10. Rollout / risk

- Flag-gated by `pages.manage.unified` (default false): zero behavior
  change for existing users; the new path only runs on the unified
  Manage surface.
- Worst-case listing latency is now bounded: `max(healthy backends) +
  30s`, vs today's unbounded.
- `dep_trace.py`: `InstalledResult` lives in `store_host` — UI imports
  stay within the sanctioned boundary (same as `CheckUpdatesResult`).
- Risk: a backend whose `listInstalled()` resolves *after* timeout
  keeps its CLI call running underneath (can't be cancelled through
  the contract). Bounded by one orphan per backend per fetch; the next
  fetch supersedes. Same honesty model as the watchdog detach.

## 11. Honest limitations

- **Timeout aborts the wait, not the work.** Same as checkUpdates: an
  orphaned CLI call runs to completion in the background.
- **No heartbeat/progress during listing.** A backend that is *slow
  but alive* (30s+ of real package enumeration on a loaded system)
  gets cut and marked partial exactly like a dead one. The 30s default
  is the mitigation; per-backend tuning is a future flag, not this
  slice.
- **Partiality is per-fetch, not persisted.** The caption disappears
  on the next successful full fetch; no flap history.
- **`search()`'s availability path is untouched** (it has its own
  `.timeout()` per stream — already covered).
