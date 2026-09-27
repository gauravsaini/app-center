# Update polling — HLD + LLD

Parent: [updates-strangle.md](updates-strangle.md), [host-wiring.md](host-wiring.md).
The unified Updates surface today only checks on first watch or manual
invalidate. This slice adds a background poll scheduler: the app checks
for updates on its own, on a flag-driven interval, and the nav badge +
Updates section update quietly.

## HLD

### 1. Goal

A store that keeps the system current must not wait for the user to
open the Updates page. The scheduler runs
`StoreHost.checkUpdatesDetailed()` periodically while the app is open
and invalidates `unifiedUpdatesResultProvider` (the single fetch behind
the updates surface; `unifiedUpdatesProvider` is its `.updates`
projection), so the badge and section reflect reality
without user action. No modals, no notification spam — badge/section
update only.

### 2. Design decisions

- **Trigger points.** (a) App start — first scheduler watch, with a
  small random stagger (0–30s) so N backends don't all hit at launch
  (update storms, hld.md §125). (b) Periodic interval while open.
  (c) Foreground resume (`didChangeAppLifecycleState → resumed`) —
  the app may have been suspended for hours; a resume check is cheap.
- **Interval flag.** `updates.poll_interval_ms`, default `21600000`
  (6h), following the `engine.stall_timeout_ms` convention in
  `MapFeatureFlags._defaults`. `<= 0` disables polling. Polling is
  additionally gated on `pages.updates.unified == true` — flag off
  means legacy update models own the badge, and the scheduler must
  never fire.
- **Coalescing.** A poll never double-fetches: before invalidating,
  the scheduler checks the provider is not already
  loading/refreshing/reloading. Manual pull-to-refresh (added to the
  Updates section in this slice, mirroring the installed list)
  restarts the interval — a manual check resets the countdown.
- **Failure posture.** The host never throws (per-backend try/catch);
  a poll that errors or returns while the provider errored keeps the
  previous list and badge. Silent retry at the next tick. No error
  UI from the scheduler — the section's own error state covers
  user-initiated checks.
- **Badge contract (unchanged).** Flag on → badge count =
  `updates.length`; `AsyncLoading` → keep previous count (no flicker);
  `AsyncError` → badge hidden. The scheduler only invalidates; the
  badge rules already handle the rest.
- **Out of scope.** Host fan-out changes — closed by
  [parallel-check-updates.md](parallel-check-updates.md):
  `StoreHost.checkUpdatesDetailed()` fans out with a per-backend
  `updates.backend_timeout_ms` budget (30s default); a hung backend is
  excluded and the section shows a quiet partial caption instead of
  stalling the tick. OS-level background scheduling (cron/systemd) —
  this is in-app polling only. Cross-backend dedupe (unchanged thesis:
  duplicates beat unsafe merges).

### 3. Testability

Same pattern as the stall watchdog: injectable `TimerFactory` on the
scheduler and an injectable `Provider<Duration>` for the poll
interval (mirroring `unifiedManageRefreshDebounceProvider`), so tests
override instead of waiting out 6h. Zero `DateTime.now()` in
scheduler logic — the timer factory owns time.

## LLD

### 4. Entities touched

| Entity | Package | Change |
|---|---|---|
| `MapFeatureFlags` | `store_host` (`flags.dart`) | + `updates.poll_interval_ms` default `21600000` |
| `updatePollSchedulerProvider` | `app_center` (`lib/manage/update_poll_scheduler.dart`) | new `Notifier` owning the timer |
| `updatePollIntervalProvider` | same file | `Provider<Duration>` from flag, tests override |
| `StoreApp` wiring | `app_center` (`lib/store/store_app.dart`) | mount a `_UpdatePollTrigger` listener widget |
| `UnifiedUpdatesSection` | `app_center` | + `RefreshIndicator` (manual refresh; resets interval) |

### 5. Scheduler contract

```dart
final updatePollIntervalProvider = Provider<Duration>(
  (ref) => Duration(milliseconds: ref.watch(storeFlagsProvider).getInt('updates.poll_interval_ms')),
  name: 'updatePollIntervalProvider',
);

final updatePollSchedulerProvider = NotifierProvider<UpdatePollScheduler, void>(
  UpdatePollScheduler.new, name: 'updatePollSchedulerProvider',
);

class UpdatePollScheduler extends Notifier<void> {
  // build(): if flag on && interval > 0: schedule first poll with
  // stagger jitter (0–30s), then periodic; hook resumed-lifecycle.
  // poll(): if provider isLoading/isRefreshing/isReloading → skip;
  //         else ref.invalidate(unifiedUpdatesResultProvider).
  // onManualRefresh(): re-arm the interval timer.
}
```

- The scheduler never reads `checkUpdatesDetailed()` directly — it
  only invalidates the provider. The provider owns the fetch.
- Lifecycle: the trigger widget mixes in `WidgetsBindingObserver`
  (the `didChangeAppLifecycleState` slot is free in `store_app.dart`)
  and calls `scheduler.onResumed()` on `resumed`. `onResumed`
  invalidates only if the last completed check is older than the
  interval (tracked as a monotonic tick count from the timer factory,
  not wall-clock).
- `TimerFactory` is passed via constructor/`ref` — reuse the host's
  `TimerFactory` typedef. Fake timers in tests (`manual advance`).

### 6. Pull-to-refresh contract (Updates section)

- Wrap the updates list in `RefreshIndicator` mirroring the installed
  list: `onRefresh` = `ref.invalidate(unifiedUpdatesProvider)` +
  await `unifiedUpdatesProvider.future` + notify scheduler
  (`onManualRefresh` → re-arm interval).
- Guard: no-op while already fetching (same invalidate-while-loading
  guard as manage-polish).

### 7. Flag contract

```dart
'updates.poll_interval_ms': 21600000, // 6h. Owner: libreapp-center.
```

- `<= 0` = polling disabled. The scheduler also requires
  `pages.updates.unified == true`; either condition false → no timer,
  no lifecycle hook. Re-evaluated on flag change (provider rebuild).

### 8. Test matrix (`app_center`)

- Flag off → no timer scheduled (fake timer factory asserts zero
  timers).
- `interval <= 0` → no timer scheduled.
- Timer fires at interval → exactly one invalidate, provider refetches
  (fake host counts `checkUpdates()` calls).
- In-flight fetch at tick → poll skipped (no double fetch).
- Manual refresh → interval re-armed (next tick pushed out by full
  interval, not from the original schedule).
- Host throws mid-fan-out (host degrades to partial/empty — never
  throws; simulate via erroring provider override) → badge keeps
  previous count, no crash, next tick still fires.
- Lifecycle resumed with stale last-check → one invalidate;
  resumed with fresh last-check → none.

### 9. Honest limitations

- Per-backend update-check timeouts are now in place
  ([parallel-check-updates.md](parallel-check-updates.md)): a hung
  backend is cut at the `updates.backend_timeout_ms` budget (30s
  default) and excluded as partial, so a poll tick can never stall
  unboundedly. A *slow but alive* backend past 30s of real metadata
  fetching is cut exactly like a dead one — the 30s default is the
  mitigation; per-backend tuning is a future flag.
- Stagger jitter uses `Random` — unseeded in prod, seeded in tests.
- In-app only: closing the app stops polling. OS background
  scheduling is a separate (Phase 2) concern.
