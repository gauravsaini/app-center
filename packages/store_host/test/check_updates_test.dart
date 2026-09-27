/// Parallel checkUpdates tests
/// (docs/architecture/parallel-check-updates.md §9).
///
/// A fake [TimerFactory] with manual [FakeTimerFactory.advance] drives
/// the host's per-backend timeout clock — no real-time sleeps, no
/// wall-clock reads. Same harness shape as stall_watchdog_test.dart.
library;

import 'dart:async';

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

import 'stub_backends.dart';

/// Lets async deliveries land. Zero-duration: not a sleep, just
/// event-loop turns.
Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Scriptable [Timer] with manual time: [FakeTimerFactory.advance] fires
/// every armed timer whose deadline falls inside the advanced window,
/// in deadline order. Same harness as stall_watchdog_test.dart.
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

UpdateInfo _update(String backendId, String nativeId, String name) =>
    UpdateInfo(
      identity: AppIdentity(backendId: backendId, nativeId: nativeId),
      name: name,
    );

/// Backend whose checkUpdates answers from a test-controlled completer —
/// completes only when the test says so (or never: the hang case).
class _ScriptedBackend extends StubSnapBackend {
  _ScriptedBackend(this.backendId, this._gate);

  final String backendId;
  final Completer<List<UpdateInfo>> _gate;

  @override
  String get id => backendId;

  @override
  Future<List<UpdateInfo>> checkUpdates() => _gate.future;
}

/// Backend whose isAvailable never completes — proves a
/// contract-violating availability hang is absorbed by the same budget.
class _HangingAvailabilityBackend extends StubSnapBackend {
  @override
  String get id => 'stuck-avail';

  @override
  Future<bool> isAvailable() => Completer<bool>().future;
}

/// Backend whose checkUpdates throws a typed StoreException.
class _TypedThrowingBackend extends StubSnapBackend {
  @override
  String get id => 'typed-thrower';

  @override
  Future<List<UpdateInfo>> checkUpdates() => Future.error(
    const NetworkException(
      debugDetail: 'stub network failure',
      backendId: 'typed-thrower',
    ),
  );
}

/// Backend whose checkUpdates throws a raw, contract-violating error.
class _RawThrowingBackend extends StubSnapBackend {
  @override
  String get id => 'raw-thrower';

  @override
  Future<List<UpdateInfo>> checkUpdates() =>
      Future.error(StateError('stub raw throw'));
}

StoreHost _host(Map<String, Object> seed, FakeTimerFactory timers) {
  final flags = MapFeatureFlags(seed);
  return StoreHost(flags: flags, timerFactory: timers.call);
}

void main() {
  group('updates.backend_timeout_ms flag', () {
    test('defaults to 30000', () {
      // ADR-010: owner libreapp-center, removal 2027-06-30 (flags.dart).
      expect(MapFeatureFlags().getInt('updates.backend_timeout_ms'), 30000);
    });
  });

  group('checkUpdatesDetailed fan-out', () {
    test('one hanging backend degrades to partial, others return', () async {
      final timers = FakeTimerFactory();
      final hang = Completer<List<UpdateInfo>>();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.hung.enabled': true,
              'updates.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              _ScriptedBackend(
                'healthy',
                Completer()..complete([_update('healthy', 'h.app', 'Healthy')]),
              ),
            )
            ..registerBackend(_ScriptedBackend('hung', hang));

      final resultFuture = host.checkUpdatesDetailed();
      await _pump();
      // The hung backend's budget expires while it never answers.
      timers.advance(const Duration(milliseconds: 101));
      final result = await resultFuture;

      expect(result.updates.map((u) => u.name), ['Healthy']);
      expect(result.partialBackendIds, ['hung']);
      expect(result.isPartial, isTrue);
      // Both backends were probed (isAvailable() -> true), so each holds
      // one probe-cache invalidation timer (platform-detection.md §4);
      // the per-backend race timers are all gone (fired or cancelled).
      expect(timers.pendingCount, 2);
    });

    test('checkUpdates() returns the partial list and never throws', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.hung.enabled': true,
              'updates.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              _ScriptedBackend(
                'healthy',
                Completer()..complete([_update('healthy', 'h.app', 'Healthy')]),
              ),
            )
            ..registerBackend(_ScriptedBackend('hung', Completer()));

      final updatesFuture = host.checkUpdates();
      await _pump();
      timers.advance(const Duration(milliseconds: 101));

      expect(await updatesFuture, hasLength(1));
    });

    test('all backends hang -> empty list, every id partial', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.a.enabled': true,
              'backend.b.enabled': true,
              'updates.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(_ScriptedBackend('a', Completer()))
            ..registerBackend(_ScriptedBackend('b', Completer()));

      final resultFuture = host.checkUpdatesDetailed();
      await _pump();
      timers.advance(const Duration(milliseconds: 101));
      final result = await resultFuture;

      expect(result.updates, isEmpty);
      expect(result.partialBackendIds, ['a', 'b']);
      expect(result.isPartial, isTrue);
    });

    test('typed StoreException excludes the backend, no throw', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.typed-thrower.enabled': true,
              'updates.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              _ScriptedBackend(
                'healthy',
                Completer()..complete([_update('healthy', 'h.app', 'Healthy')]),
              ),
            )
            ..registerBackend(_TypedThrowingBackend());

      final result = await host.checkUpdatesDetailed();

      expect(result.updates.map((u) => u.name), ['Healthy']);
      expect(result.partialBackendIds, ['typed-thrower']);
    });

    test('raw throw excludes the backend, no throw', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.raw-thrower.enabled': true,
              'updates.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              _ScriptedBackend(
                'healthy',
                Completer()..complete([_update('healthy', 'h.app', 'Healthy')]),
              ),
            )
            ..registerBackend(_RawThrowingBackend());

      final result = await host.checkUpdatesDetailed();

      expect(result.updates.map((u) => u.name), ['Healthy']);
      expect(result.partialBackendIds, ['raw-thrower']);
    });

    test('budget is read from the flag at call time', () async {
      final timers = FakeTimerFactory();
      var budget = 100;
      var n = 0;
      Future<CheckUpdatesResult> checkAfter(Duration at) async {
        final id = 'slow$n';
        n++;
        final f = MapFeatureFlags({
          'backend.$id.enabled': true,
          'updates.backend_timeout_ms': budget,
        });
        final h = StoreHost(flags: f, timerFactory: timers.call);
        final gate = Completer<List<UpdateInfo>>();
        h.registerBackend(_ScriptedBackend(id, gate));
        final future = h.checkUpdatesDetailed();
        await _pump();
        timers.advance(at);
        gate.complete([_update(id, 's.app', 'Slow')]);
        return future;
      }

      // Completing at fake-99ms beats the 100ms budget: full result.
      var result = await checkAfter(const Duration(milliseconds: 99));
      expect(result.isPartial, isFalse);
      expect(result.updates, hasLength(1));

      // Completing at fake-101ms misses it: partial.
      result = await checkAfter(const Duration(milliseconds: 101));
      expect(result.isPartial, isTrue);
      expect(result.partialBackendIds, ['slow1']);

      // The flag is re-read per call: raising it to 1000ms admits the
      // same 101ms completion.
      budget = 1000;
      result = await checkAfter(const Duration(milliseconds: 101));
      expect(result.isPartial, isFalse);
      expect(result.updates, hasLength(1));
    });

    test('non-positive flag falls back to the 30000 default', () async {
      final timers = FakeTimerFactory();
      var n = 0;
      Future<CheckUpdatesResult> checkAfter(Duration at) async {
        final id = 'slow$n';
        n++;
        final f = MapFeatureFlags({
          'backend.$id.enabled': true,
          'updates.backend_timeout_ms': 0,
        });
        final h = StoreHost(flags: f, timerFactory: timers.call);
        final gate = Completer<List<UpdateInfo>>();
        h.registerBackend(_ScriptedBackend(id, gate));
        final future = h.checkUpdatesDetailed();
        await _pump();
        timers.advance(at);
        gate.complete([_update(id, 's.app', 'Slow')]);
        return future;
      }

      // 29s < 30s default: full.
      var result = await checkAfter(const Duration(seconds: 29));
      expect(result.isPartial, isFalse);

      // 31s > 30s default: partial. Disabled is never an option.
      result = await checkAfter(const Duration(seconds: 31));
      expect(result.isPartial, isTrue);
    });

    test('results keep registration order, not completion order', () async {
      final timers = FakeTimerFactory();
      final slowGate = Completer<List<UpdateInfo>>();
      final host =
          _host({
              'backend.slow.enabled': true,
              'backend.fast.enabled': true,
              'updates.backend_timeout_ms': 1000,
            }, timers)
            // Slow registered FIRST, completes LAST.
            ..registerBackend(_ScriptedBackend('slow', slowGate))
            ..registerBackend(
              _ScriptedBackend(
                'fast',
                Completer()..complete([_update('fast', 'f.app', 'Fast')]),
              ),
            );

      final resultFuture = host.checkUpdatesDetailed();
      await _pump();
      timers.advance(const Duration(milliseconds: 50));
      slowGate.complete([_update('slow', 's.app', 'Slow')]);
      final result = await resultFuture;

      expect(result.isPartial, isFalse);
      expect(result.updates.map((u) => u.name), ['Slow', 'Fast']);
    });

    test('hanging isAvailable() is absorbed by the same budget', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.stuck-avail.enabled': true,
              'updates.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              _ScriptedBackend(
                'healthy',
                Completer()..complete([_update('healthy', 'h.app', 'Healthy')]),
              ),
            )
            ..registerBackend(_HangingAvailabilityBackend());

      final resultFuture = host.checkUpdatesDetailed();
      await _pump();
      timers.advance(const Duration(milliseconds: 101));
      final result = await resultFuture;

      expect(result.updates.map((u) => u.name), ['Healthy']);
      expect(result.partialBackendIds, ['stuck-avail']);
      expect(result.isPartial, isTrue);
    });

    test('orphan completing late is dropped, its error absorbed', () async {
      var unhandled = 0;
      await runZonedGuarded(() async {
        final timers = FakeTimerFactory();
        final gate = Completer<List<UpdateInfo>>();
        final host = _host({
          'backend.late.enabled': true,
          'updates.backend_timeout_ms': 100,
        }, timers)..registerBackend(_ScriptedBackend('late', gate));

        final resultFuture = host.checkUpdatesDetailed();
        await _pump();
        timers.advance(const Duration(milliseconds: 101));
        final result = await resultFuture;
        expect(result.updates, isEmpty);
        expect(result.partialBackendIds, ['late']);

        // The orphan answers AFTER the timeout: value dropped...
        gate.complete([_update('late', 'l.app', 'Late')]);
        await _pump();
        expect((await resultFuture).updates, isEmpty);

        // ...and a late error never surfaces as an unhandled async
        // error (the orphan listener swallows it).
        final errGate = Completer<List<UpdateInfo>>();
        final host2 = _host({
          'backend.err.enabled': true,
          'updates.backend_timeout_ms': 100,
        }, timers)..registerBackend(_ScriptedBackend('err', errGate));
        final result2Future = host2.checkUpdatesDetailed();
        await _pump();
        timers.advance(const Duration(milliseconds: 101));
        expect((await result2Future).partialBackendIds, ['err']);
        errGate.completeError(StateError('late orphan throw'));
        await _pump();
      }, (Object e, StackTrace s) => unhandled++);
      expect(unhandled, 0);
    });

    test('flag-disabled backends are skipped without a timeout', () async {
      final timers = FakeTimerFactory();
      final host = _host({
        'backend.off.enabled': false,
        'updates.backend_timeout_ms': 100,
      }, timers)..registerBackend(_ScriptedBackend('off', Completer()));

      final result = await host.checkUpdatesDetailed();

      expect(result.updates, isEmpty);
      expect(result.partialBackendIds, isEmpty);
      expect(result.isPartial, isFalse);
      expect(timers.pendingCount, 0);
    });
  });
}
