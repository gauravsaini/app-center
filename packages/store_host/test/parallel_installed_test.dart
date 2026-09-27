/// Parallel installed tests
/// (docs/architecture/parallel-installed.md §9).
///
/// A fake [TimerFactory] with manual [FakeTimerFactory.advance] drives
/// the host's per-backend timeout clock — no real-time sleeps, no
/// wall-clock reads. Same harness shape as check_updates_test.dart.
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
/// in deadline order. Same harness as check_updates_test.dart.
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

/// Backend whose listInstalled answers from a test-controlled completer —
/// completes only when the test says so (or never: the hang case). The
/// gate is re-armable so one backend can serve several calls on the
/// same host.
class _ScriptedInstalledBackend extends StubSnapBackend {
  _ScriptedInstalledBackend(this.backendId, [Completer<List<AppInfo>>? gate])
    : gate = gate ?? Completer<List<AppInfo>>();

  final String backendId;
  Completer<List<AppInfo>> gate;

  @override
  String get id => backendId;

  @override
  Future<List<AppInfo>> listInstalled() => gate.future;
}

/// Backend whose isAvailable never completes — proves a
/// contract-violating availability hang is absorbed by the same budget.
class _HangingAvailabilityInstalledBackend extends StubSnapBackend {
  @override
  String get id => 'stuck-avail';

  @override
  Future<bool> isAvailable() => Completer<bool>().future;
}

/// Backend whose listInstalled throws a raw, contract-violating error.
class _RawThrowingInstalledBackend extends StubSnapBackend {
  @override
  String get id => 'raw-thrower';

  @override
  Future<List<AppInfo>> listInstalled() =>
      Future.error(StateError('stub raw throw'));
}

StoreHost _host(Map<String, Object> seed, FakeTimerFactory timers) {
  final flags = MapFeatureFlags(seed);
  return StoreHost(flags: flags, timerFactory: timers.call);
}

void main() {
  group('installed.backend_timeout_ms flag', () {
    test('defaults to 30000', () {
      // ADR-010: owner libreapp-center, removal 2027-06-30 (flags.dart).
      expect(MapFeatureFlags().getInt('installed.backend_timeout_ms'), 30000);
    });
  });

  group('installedDetailed fan-out', () {
    test('one hanging backend degrades to partial, others return', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.hung.enabled': true,
              'installed.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              StubInstalledBackend(
                backendId: 'healthy',
                apps: [stubInstalledApp('healthy', 'h.app')],
              ),
            )
            ..registerBackend(_ScriptedInstalledBackend('hung'));

      final resultFuture = host.installedDetailed();
      await _pump();
      // The hung backend's budget expires while it never answers.
      timers.advance(const Duration(milliseconds: 101));
      final result = await resultFuture;

      expect(result.apps.map((u) => u.groupId), ['healthy:h.app']);
      expect(result.partialBackendIds, ['hung']);
      expect(result.isPartial, isTrue);
      // The orphan's timer was the only one armed; the healthy
      // backend's timer was cancelled on completion.
      expect(timers.pendingCount, 0);
    });

    test('installed() returns the partial list and never throws', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.hung.enabled': true,
              'installed.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              StubInstalledBackend(
                backendId: 'healthy',
                apps: [stubInstalledApp('healthy', 'h.app')],
              ),
            )
            ..registerBackend(_ScriptedInstalledBackend('hung'));

      final appsFuture = host.installed();
      await _pump();
      timers.advance(const Duration(milliseconds: 101));

      expect(await appsFuture, hasLength(1));
    });

    test('all backends hang -> empty list, every id partial', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.a.enabled': true,
              'backend.b.enabled': true,
              'installed.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(_ScriptedInstalledBackend('a'))
            ..registerBackend(_ScriptedInstalledBackend('b'));

      final resultFuture = host.installedDetailed();
      await _pump();
      timers.advance(const Duration(milliseconds: 101));
      final result = await resultFuture;

      expect(result.apps, isEmpty);
      expect(result.partialBackendIds, ['a', 'b']);
      expect(result.isPartial, isTrue);
    });

    test('typed StoreException excludes the backend, no throw', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.thrower.enabled': true,
              'installed.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              StubInstalledBackend(
                backendId: 'healthy',
                apps: [stubInstalledApp('healthy', 'h.app')],
              ),
            )
            // Throws BackendUnavailableException from listInstalled().
            ..registerBackend(ThrowingInstalledBackend());

      final result = await host.installedDetailed();

      expect(result.apps.map((u) => u.groupId), ['healthy:h.app']);
      expect(result.partialBackendIds, ['thrower']);
    });

    test('raw throw excludes the backend, no throw', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.raw-thrower.enabled': true,
              'installed.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              StubInstalledBackend(
                backendId: 'healthy',
                apps: [stubInstalledApp('healthy', 'h.app')],
              ),
            )
            ..registerBackend(_RawThrowingInstalledBackend());

      final result = await host.installedDetailed();

      expect(result.apps.map((u) => u.groupId), ['healthy:h.app']);
      expect(result.partialBackendIds, ['raw-thrower']);
    });

    test('budget is read from the flag at call time', () async {
      final timers = FakeTimerFactory();
      final flags = MapFeatureFlags({
        'backend.slow.enabled': true,
        'installed.backend_timeout_ms': 100,
      });
      final host = StoreHost(flags: flags, timerFactory: timers.call);
      final backend = _ScriptedInstalledBackend('slow');
      host.registerBackend(backend);

      Future<InstalledResult> listAfter(Duration at) async {
        backend.gate = Completer<List<AppInfo>>();
        final future = host.installedDetailed();
        await _pump();
        timers.advance(at);
        backend.gate.complete([stubInstalledApp('slow', 's.app')]);
        return future;
      }

      // Completing at fake-99ms beats the 100ms budget: full result.
      var result = await listAfter(const Duration(milliseconds: 99));
      expect(result.isPartial, isFalse);
      expect(result.apps, hasLength(1));

      // Completing at fake-101ms misses it: partial.
      result = await listAfter(const Duration(milliseconds: 101));
      expect(result.isPartial, isTrue);
      expect(result.partialBackendIds, ['slow']);

      // The flag is re-read per call: setFlag(1000) on the same host
      // admits the same 101ms completion.
      flags.setFlag('installed.backend_timeout_ms', 1000);
      result = await listAfter(const Duration(milliseconds: 101));
      expect(result.isPartial, isFalse);
      expect(result.apps, hasLength(1));
    });

    test('non-positive flag falls back to the 30000 default', () async {
      final timers = FakeTimerFactory();
      final flags = MapFeatureFlags({
        'backend.slow.enabled': true,
        'installed.backend_timeout_ms': 0,
      });
      final host = StoreHost(flags: flags, timerFactory: timers.call);
      final backend = _ScriptedInstalledBackend('slow');
      host.registerBackend(backend);

      Future<InstalledResult> listAfter(Duration at) async {
        backend.gate = Completer<List<AppInfo>>();
        final future = host.installedDetailed();
        await _pump();
        timers.advance(at);
        backend.gate.complete([stubInstalledApp('slow', 's.app')]);
        return future;
      }

      // 29s < 30s default: full.
      var result = await listAfter(const Duration(seconds: 29));
      expect(result.isPartial, isFalse);

      // 31s > 30s default: partial. Disabled is never an option.
      result = await listAfter(const Duration(seconds: 31));
      expect(result.isPartial, isTrue);
    });

    test('results keep registration order, not completion order', () async {
      final timers = FakeTimerFactory();
      final a = _ScriptedInstalledBackend('a');
      final b = _ScriptedInstalledBackend('b');
      final c = _ScriptedInstalledBackend('c');
      final host =
          _host({
              'backend.a.enabled': true,
              'backend.b.enabled': true,
              'backend.c.enabled': true,
              'installed.backend_timeout_ms': 1000,
            }, timers)
            // Registered A, B, C — completed C, A, B.
            ..registerBackend(a)
            ..registerBackend(b)
            ..registerBackend(c);

      final resultFuture = host.installedDetailed();
      await _pump();
      c.gate.complete([stubInstalledApp('c', 'c.app')]);
      a.gate.complete([stubInstalledApp('a', 'a.app')]);
      timers.advance(const Duration(milliseconds: 50));
      b.gate.complete([stubInstalledApp('b', 'b.app')]);
      final result = await resultFuture;

      expect(result.isPartial, isFalse);
      expect(result.apps.map((u) => u.groupId), [
        'a:a.app',
        'b:b.app',
        'c:c.app',
      ]);
    });

    test(
      'same nativeId across backends produces one card each, no merge',
      () async {
        final timers = FakeTimerFactory();
        final host =
            _host({
                'backend.snap.enabled': true,
                'backend.deb.enabled': true,
                'installed.backend_timeout_ms': 1000,
              }, timers)
              ..registerBackend(
                StubInstalledBackend(
                  backendId: 'snap',
                  apps: [stubInstalledApp('snap', 'x')],
                ),
              )
              ..registerBackend(
                StubInstalledBackend(
                  backendId: 'deb',
                  apps: [stubInstalledApp('deb', 'x')],
                ),
              );

        final result = await host.installedDetailed();

        expect(result.isPartial, isFalse);
        expect(result.apps, hasLength(2));
        expect(result.apps.map((u) => u.groupId), ['snap:x', 'deb:x']);
      },
    );

    test('hanging isAvailable() is absorbed by the same budget', () async {
      final timers = FakeTimerFactory();
      final host =
          _host({
              'backend.healthy.enabled': true,
              'backend.stuck-avail.enabled': true,
              'installed.backend_timeout_ms': 100,
            }, timers)
            ..registerBackend(
              StubInstalledBackend(
                backendId: 'healthy',
                apps: [stubInstalledApp('healthy', 'h.app')],
              ),
            )
            ..registerBackend(_HangingAvailabilityInstalledBackend());

      final resultFuture = host.installedDetailed();
      await _pump();
      timers.advance(const Duration(milliseconds: 101));
      final result = await resultFuture;

      expect(result.apps.map((u) => u.groupId), ['healthy:h.app']);
      expect(result.partialBackendIds, ['stuck-avail']);
      expect(result.isPartial, isTrue);
    });

    test('orphan completing late is dropped, its error absorbed', () async {
      var unhandled = 0;
      await runZonedGuarded(() async {
        final timers = FakeTimerFactory();
        final backend = _ScriptedInstalledBackend('late');
        final host = _host({
          'backend.late.enabled': true,
          'installed.backend_timeout_ms': 100,
        }, timers)..registerBackend(backend);

        final resultFuture = host.installedDetailed();
        await _pump();
        timers.advance(const Duration(milliseconds: 101));
        final result = await resultFuture;
        expect(result.apps, isEmpty);
        expect(result.partialBackendIds, ['late']);

        // The orphan answers AFTER the timeout: value dropped...
        backend.gate.complete([stubInstalledApp('late', 'l.app')]);
        await _pump();
        expect((await resultFuture).apps, isEmpty);

        // ...and a late error never surfaces as an unhandled async
        // error (the orphan listener swallows it).
        final errBackend = _ScriptedInstalledBackend('err');
        final host2 = _host({
          'backend.err.enabled': true,
          'installed.backend_timeout_ms': 100,
        }, timers)..registerBackend(errBackend);
        final result2Future = host2.installedDetailed();
        await _pump();
        timers.advance(const Duration(milliseconds: 101));
        expect((await result2Future).partialBackendIds, ['err']);
        errBackend.gate.completeError(StateError('late orphan throw'));
        await _pump();
      }, (Object e, StackTrace s) => unhandled++);
      expect(unhandled, 0);
    });

    test('flag-disabled backends are skipped without a timeout', () async {
      final timers = FakeTimerFactory();
      final host = _host({
        'backend.off.enabled': false,
        'installed.backend_timeout_ms': 100,
      }, timers)..registerBackend(_ScriptedInstalledBackend('off'));

      final result = await host.installedDetailed();

      expect(result.apps, isEmpty);
      expect(result.partialBackendIds, isEmpty);
      expect(result.isPartial, isFalse);
      expect(timers.pendingCount, 0);
    });
  });
}
