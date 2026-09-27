/// Background update-poll scheduler
/// (docs/architecture/update-polling.md — HLD §1–§3, LLD §4–§7).
///
/// While the app is open, the scheduler periodically invalidates
/// [unifiedUpdatesResultProvider] so the nav badge and the Updates section
/// reflect reality without user action. No modals, no notifications —
///
/// Trigger points:
/// - app start: first scheduler watch, with a 0–30s stagger so N
///   backends don't all hit at launch (update storms);
/// - periodic interval while open ([updatePollIntervalProvider]);
/// - foreground resume ([UpdatePollScheduler.onResumed]) — only when
///   the last completed check is at least one interval old.
///
/// Contract notes:
/// - The scheduler never calls `checkUpdatesDetailed()` directly — it
///   only invalidates the provider; the provider owns the fetch.
/// - Coalescing: a tick never double-fetches — the poll is skipped
///   while the provider is loading/refreshing/reloading.
/// - Failure posture: the host never throws, so a failed poll keeps
///   the previous list; the next tick retries silently. No error UI
///   from the scheduler.
/// - Gated on `pages.updates.unified == true` AND
///   `updates.poll_interval_ms > 0`; either false → no timer, no
///   resume hook. Re-evaluated on flag change (provider rebuild).
/// - Injectable time: [updatePollTimerFactoryProvider] reuses the
///   host's [TimerFactory] typedef; the scheduler never reads
///   `DateTime.now()` — staleness is a monotonic tick count off the
///   scheduler's own timer firings.
/// - Stagger jitter comes from [updatePollRandomProvider]: unseeded in
///   prod, seeded in tests.
///
/// No `backend_*` import by design: this file sees only the host, the
/// contracts, and app_center internals.
library;

import 'dart:async';
import 'dart:math';

import 'package:app_center/manage/unified_updates_provider.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// Poll interval for the background update check, sourced from the
/// `updates.poll_interval_ms` flag (default 6h). A provider (not a
/// const) so tests override it instead of waiting out the real delay —
/// same pattern as `unifiedManageRefreshDebounceProvider`.
final updatePollIntervalProvider = Provider<Duration>(
  (ref) => Duration(
    milliseconds: ref
        .watch(storeFlagsProvider)
        .getInt('updates.poll_interval_ms'),
  ),
  name: 'updatePollIntervalProvider',
);

/// Clock for [UpdatePollScheduler]: production uses real one-shot
/// timers; tests override with a fake factory and advance it manually.
/// Same injectable-time pattern as the host's stall watchdog.
final updatePollTimerFactoryProvider = Provider<TimerFactory>(
  (_) => Timer.new,
  name: 'updatePollTimerFactoryProvider',
);

/// Jitter source for the launch stagger (0–30s, update-polling.md §9).
/// Unseeded in prod; tests override with a seeded [Random].
final updatePollRandomProvider = Provider<Random>(
  (_) => Random(),
  name: 'updatePollRandomProvider',
);

/// Owns the background update-poll timer. Kept alive for the app's
/// lifetime by the `_UpdatePollTrigger` in `store_app.dart`, which also
/// routes foreground resumes into [UpdatePollScheduler.onResumed].
final updatePollSchedulerProvider = NotifierProvider<UpdatePollScheduler, void>(
  UpdatePollScheduler.new,
  name: 'updatePollSchedulerProvider',
);

class UpdatePollScheduler extends Notifier<void> {
  Timer? _timer;
  bool _enabled = false;
  Duration _interval = Duration.zero;

  /// Interval-period boundaries crossed since the last completed check,
  /// counted off the scheduler's own timer firings — never the wall
  /// clock (update-polling.md §5). A resume only polls when at least
  /// one full interval elapsed without a completed check.
  int _periodsSinceCheck = 0;

  @override
  void build() {
    _enabled =
        ref.watch(storeFlagsProvider).isEnabled('pages.updates.unified') &&
        ref.watch(updatePollIntervalProvider) > Duration.zero;
    _interval = ref.read(updatePollIntervalProvider);
    _periodsSinceCheck = 0;
    _timer?.cancel();
    _timer = null;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    if (!_enabled) return;
    // A completed check resets the staleness counter — covers periodic
    // polls, manual refreshes, and update-all invalidations alike. A
    // refresh still in flight (or an error, which keeps the previous
    // value as AsyncError) does not reset: the check isn't done yet.
    // Subscribed only while enabled: otherwise merely watching the
    // scheduler would spin up the host and fire a check for nothing.
    ref.listen(unifiedUpdatesResultProvider, (_, next) {
      if (next is AsyncData &&
          !next.isLoading &&
          !next.isRefreshing &&
          !next.isReloading) {
        _periodsSinceCheck = 0;
      }
    });
    _armStaggeredFirstPoll();
  }

  /// First poll after (re)build, staggered 0–30s so N backends don't
  /// all check at launch (update-polling.md §2).
  void _armStaggeredFirstPoll() {
    final factory = ref.read(updatePollTimerFactoryProvider);
    final stagger = Duration(
      seconds: ref.read(updatePollRandomProvider).nextInt(31),
    );
    _timer?.cancel();
    _timer = factory(stagger, () {
      _poll();
      _armPeriodic();
    });
  }

  void _armPeriodic() {
    final factory = ref.read(updatePollTimerFactoryProvider);
    _timer?.cancel();
    _timer = factory(_interval, () {
      // One full interval elapsed since the last arming without a
      // completed check being recorded in between.
      _periodsSinceCheck++;
      _poll();
      _armPeriodic();
    });
  }

  /// One poll tick. Coalescing (update-polling.md §2): never
  /// double-fetch — skip while a check is already in flight. The
  /// scheduler invalidates [unifiedUpdatesResultProvider] only (the
  /// single fetch behind the updates surface); it never calls
  /// `checkUpdatesDetailed()` directly.
  void _poll() {
    final updates = ref.read(unifiedUpdatesResultProvider);
    if (updates.isLoading || updates.isRefreshing || updates.isReloading) {
      return;
    }
    ref.invalidate(unifiedUpdatesResultProvider);
  }

  /// Foreground-resume hook, called by `_UpdatePollTrigger` on
  /// `AppLifecycleState.resumed`. Polls only when the last completed
  /// check is at least one interval old (update-polling.md §5).
  void onResumed() {
    if (!_enabled || _periodsSinceCheck < 1) return;
    _periodsSinceCheck = 0;
    _poll();
  }

  /// Manual pull-to-refresh hook: a manual check resets the countdown
  /// (update-polling.md §2) — the next automatic poll fires a full
  /// interval from now, not from the original schedule.
  void onManualRefresh() {
    if (!_enabled) return;
    _periodsSinceCheck = 0;
    _armPeriodic();
  }
}
