/// Update-poll scheduler tests (docs/architecture/update-polling.md §8).
///
/// A fake [TimerFactory] with manual [FakeTimerFactory.advance] drives
/// the scheduler's clock — no real-time sleeps, no wall-clock reads —
/// mirroring the stall watchdog's test clock. The updates provider is
/// overridden with a scriptable implementation so every refetch is
/// counted; the poll interval comes from the `updates.poll_interval_ms`
/// flag (short values, not 6h) and the launch stagger is deterministic
/// via a seeded [Random].
library;

import 'dart:async';
import 'dart:math';

import 'package:app_center/manage/unified_updates_provider.dart';
import 'package:app_center/manage/update_poll_scheduler.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Lets async provider deliveries land. Zero-duration: not a sleep,
/// just event-loop turns.
Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Scriptable [Timer] with manual time: [FakeTimerFactory.advance]
/// fires every armed timer whose deadline falls inside the advanced
/// window, in deadline order. Same shape as the stall watchdog's test
/// clock (store_host/test/stall_watchdog_test.dart).
class FakeTimerFactory {
  FakeTimerFactory();

  Duration _now = Duration.zero;
  final _timers = <_FakeTimer>[];

  Timer call(Duration duration, void Function() callback) {
    final timer = _FakeTimer(_now + duration, callback, _timers.remove);
    _timers.add(timer);
    return timer;
  }

  /// Currently armed (not fired, not cancelled) timers.
  int get pendingCount => _timers.where((t) => t.isActive).length;

  void advance(Duration by) {
    final target = _now + by;
    for (;;) {
      _FakeTimer? next;
      for (final t in _timers) {
        if (!t.isActive || t.due > target) continue;
        if (next == null || t.due < next.due) next = t;
      }
      if (next == null) break;
      _now = next.due;
      next.fire();
    }
    _now = target;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this._callback, this._onFired);

  Duration due;
  final void Function() _callback;
  final void Function(_FakeTimer) _onFired;
  var _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _onFired(this);
    _callback();
  }
}

typedef _Fetch = Future<CheckUpdatesResult> Function();

/// Test harness: a container with the scheduler live, a fake clock, and
/// a counted updates provider.
class _Harness {
  _Harness._(this.container, this.timers);

  final ProviderContainer container;
  final FakeTimerFactory timers;

  /// How many times the updates provider (re)fetched.
  int get fetchCount => _fetchCount;
  int _fetchCount = 0;

  UpdatePollScheduler get scheduler =>
      container.read(updatePollSchedulerProvider.notifier);
}

_Harness _makeScheduler({
  bool unified = true,
  int intervalMs = 60000,
  _Fetch? fetch,
}) {
  final timers = FakeTimerFactory();
  late final _Harness harness;
  Future<CheckUpdatesResult> countedFetch() async {
    harness._fetchCount++;
    if (fetch != null) return fetch();
    return const CheckUpdatesResult(updates: [], partialBackendIds: []);
  }

  final container = createContainer(
    overrides: [
      storeFlagsProvider.overrideWithValue(
        MapFeatureFlags({
          'pages.updates.unified': unified,
          'updates.poll_interval_ms': intervalMs,
        }),
      ),
      updatePollTimerFactoryProvider.overrideWithValue(timers.call),
      updatePollRandomProvider.overrideWithValue(Random(7)),
      unifiedUpdatesResultProvider.overrideWith((_) => countedFetch()),
    ],
  );
  harness = _Harness._(container, timers);
  // Instantiating the scheduler subscribes to
  // unifiedUpdatesResultProvider, which triggers the initial check.
  container.read(updatePollSchedulerProvider);
  return harness;
}

UpdateInfo _update(String nativeId, String name) => UpdateInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
);

void main() {
  tearDown(resetAllServices);

  group('gating', () {
    test('flag off → no timer scheduled', () {
      final h = _makeScheduler(unified: false);
      expect(h.timers.pendingCount, 0);
      // Lifecycle/manual hooks are no-ops while disabled.
      h.scheduler.onResumed();
      h.scheduler.onManualRefresh();
      expect(h.timers.pendingCount, 0);
    });

    test('interval <= 0 → no timer scheduled', () {
      final h = _makeScheduler(intervalMs: 0);
      expect(h.timers.pendingCount, 0);
      h.timers.advance(const Duration(days: 1));
      // Fully inert while disabled: no subscription, so not even the
      // initial check fires — and never a poll.
      expect(h.fetchCount, 0);
    });

    test('negative interval → no timer scheduled', () {
      final h = _makeScheduler(intervalMs: -1);
      expect(h.timers.pendingCount, 0);
      h.timers.advance(const Duration(days: 1));
      // Fully inert while disabled: no subscription, so not even the
      // initial check fires — and never a poll.
      expect(h.fetchCount, 0);
    });

    test('poll interval flag defaults to 6h', () {
      // update-polling.md §7: the flag the interval provider reads.
      expect(MapFeatureFlags().getInt('updates.poll_interval_ms'), 21600000);
    });
  });

  group('polling', () {
    test('staggered first poll then exactly one poll per interval', () async {
      final h = _makeScheduler();
      // Settle the initial check: a tick only polls when the provider
      // is neither loading nor refreshing, so the clock must not move
      // before the first fetch lands.
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 1);

      // Stagger is 0–30s; advancing past the max guarantees it fired.
      h.timers.advance(const Duration(seconds: 31));
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 2);

      h.timers.advance(const Duration(seconds: 60));
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 3);

      h.timers.advance(const Duration(seconds: 60));
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 4);
    });

    test('in-flight fetch at tick → poll skipped, no double fetch', () async {
      final gate = Completer<CheckUpdatesResult>();
      var calls = 0;
      final h = _makeScheduler(
        fetch: () {
          calls++;
          // First check completes; the staggered poll hangs.
          return calls == 1
              ? Future.value(
                  const CheckUpdatesResult(
                    updates: [],
                    partialBackendIds: [],
                  ),
                )
              : gate.future;
        },
      );
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(calls, 1);

      // The staggered poll starts and hangs: exactly one new fetch.
      h.timers.advance(const Duration(seconds: 31));
      await _pump();
      expect(calls, 2);

      // A full interval passes with the check hung: the tick must not
      // double-fetch (update-polling.md §2, §9), but the timer chain
      // stays armed — a hang delays, never duplicates, checks.
      h.timers.advance(const Duration(seconds: 60));
      await _pump();
      expect(calls, 2);
      expect(h.timers.pendingCount, 1);

      // The hung check completes; the next tick polls again.
      gate.complete(
        const CheckUpdatesResult(updates: [], partialBackendIds: []),
      );
      await h.container.read(unifiedUpdatesResultProvider.future);
      h.timers.advance(const Duration(seconds: 60));
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(calls, 3);
    });

    test('manual refresh re-arms the interval from now', () async {
      final h = _makeScheduler();
      await h.container.read(unifiedUpdatesResultProvider.future);
      h.timers.advance(const Duration(seconds: 31));
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 2);

      // A manual check resets the countdown (update-polling.md §2): the
      // next automatic poll fires a full interval from now (t=91), not
      // from the original schedule (t<=90).
      h.scheduler.onManualRefresh();
      expect(h.timers.pendingCount, 1);
      h.timers.advance(const Duration(seconds: 59));
      await _pump();
      expect(h.fetchCount, 2);
      h.timers.advance(const Duration(seconds: 1));
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 3);
    });

    test(
      'erroring check → no crash, badge keeps previous count, '
      'next tick retries',
      () async {
        var calls = 0;
        final h = _makeScheduler(
          fetch: () {
            calls++;
            // The staggered poll errors (simulating a breakage above the
            // host, which itself never throws); the retry succeeds.
            if (calls == 2) throw StateError('boom');
            return Future.value(
              CheckUpdatesResult(
                updates: [
                  _update('fake.app1', 'Fake App One'),
                  _update('fake.app2', 'Fake App Two'),
                ],
                partialBackendIds: const [],
              ),
            );
          },
        );
        await h.container.read(unifiedUpdatesResultProvider.future);
        expect(calls, 1);

        final states = <AsyncValue<CheckUpdatesResult>>[];
        h.container.listen(unifiedUpdatesResultProvider, (_, next) {
          states.add(next);
        });

        // The staggered poll invalidates; the rebuild throws. Nothing
        // escapes the timer machinery — no crash.
        h.timers.advance(const Duration(seconds: 31));
        await expectLater(
          h.container.read(unifiedUpdatesResultProvider.future),
          throwsStateError,
        );
        expect(calls, 2);
        expect(
          h.container.read(unifiedUpdatesResultProvider),
          isA<AsyncError<CheckUpdatesResult>>(),
        );

        // While the failing poll was in flight the provider carried the
        // previous result (a refresh keeps the previous value — Riverpod
        // surfaces it as AsyncData with the loading flags set, not
        // AsyncLoading) — that is what the nav badge reads, so it keeps
        // the previous count instead of flickering (update-polling.md
        // §2).
        final inFlight = states
            .where((s) => s.isLoading || s.isRefreshing || s.isReloading)
            .single;
        expect(inFlight.valueOrNull?.updates, hasLength(2));

        // The timer chain survives the error: silent retry at the next
        // tick (update-polling.md §2).
        expect(h.timers.pendingCount, 1);
        h.timers.advance(const Duration(seconds: 60));
        await h.container.read(unifiedUpdatesResultProvider.future);
        expect(calls, 3);
        expect(
          h.container.read(unifiedUpdatesResultProvider),
          isA<AsyncData<CheckUpdatesResult>>(),
        );
      },
    );
  });

  group('foreground resume', () {
    test('fresh last check → no invalidate', () async {
      final h = _makeScheduler();
      await h.container.read(unifiedUpdatesResultProvider.future);
      h.timers.advance(const Duration(seconds: 31));
      // Staggered poll completes → the last completed check is fresh.
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(h.fetchCount, 2);

      h.scheduler.onResumed();
      await _pump();
      expect(h.fetchCount, 2);
    });

    test('stale last check → one invalidate', () async {
      final gate = Completer<CheckUpdatesResult>();
      var calls = 0;
      final h = _makeScheduler(
        fetch: () {
          calls++;
          // The invalidated check hangs, then errors — no check ever
          // completes with a value after the initial one, so the last
          // completed check goes stale while nothing is in flight.
          if (calls == 2) return gate.future;
          return Future.value(
            const CheckUpdatesResult(updates: [], partialBackendIds: []),
          );
        },
      );

      // A check starts and hangs through the staggered poll and a full
      // interval tick (both ticks correctly skip the in-flight fetch).
      h.container.invalidate(unifiedUpdatesResultProvider);
      await _pump();
      expect(calls, 2);
      h.timers.advance(const Duration(seconds: 31));
      await _pump();
      h.timers.advance(const Duration(seconds: 60));
      await _pump();
      expect(calls, 2);

      // The hung check errors: nothing in flight, last completed check
      // is stale → resume polls exactly once...
      gate.completeError(StateError('boom'));
      await _pump();
      h.scheduler.onResumed();
      await h.container.read(unifiedUpdatesResultProvider.future);
      expect(calls, 3);

      // ...and a second resume with the fresh check is a no-op.
      h.scheduler.onResumed();
      await _pump();
      expect(calls, 3);
    });
  });
}
