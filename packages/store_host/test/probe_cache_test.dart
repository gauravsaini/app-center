/// Probe-cache tests (docs/architecture/platform-detection.md §9).
///
/// Host-side `isAvailable()` memoization with a TTL from the
/// `host.probe_cache_ttl_ms` flag. A fake [TimerFactory] with manual
/// [FakeTimerFactory.advance] drives expiry — no real-time sleeps, no
/// wall-clock reads. Same harness shape as check_updates_test.dart.
library;

import 'dart:async';

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

import 'stub_backends.dart';

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

/// Backend that counts its `isAvailable()` invocations.
class _CountingBackend extends StubSnapBackend {
  _CountingBackend(this.backendId, {this.available = true});

  final String backendId;
  final bool available;
  var probeCount = 0;

  @override
  String get id => backendId;

  @override
  Future<bool> isAvailable() async {
    probeCount++;
    return available;
  }
}

StoreHost _host(Map<String, Object> seed, FakeTimerFactory timers) {
  final flags = MapFeatureFlags(seed);
  return StoreHost(flags: flags, timerFactory: timers.call);
}

const _fedoraPlatform = PlatformInfo(
  id: 'fedora',
  idLike: ['fedora'],
  prettyName: 'Fedora Linux',
);

void main() {
  group('probe cache', () {
    test('two enabledBackends() calls, TTL not expired -> one probe', () async {
      final timers = FakeTimerFactory();
      final backend = _CountingBackend('probe-a');
      final host = _host({'backend.probe-a.enabled': true}, timers)
        ..registerBackend(backend);

      expect((await host.enabledBackends()).map((b) => b.id), ['probe-a']);
      expect((await host.enabledBackends()).map((b) => b.id), ['probe-a']);
      expect(backend.probeCount, 1);
    });

    test('past the TTL the next call re-probes', () async {
      final timers = FakeTimerFactory();
      final backend = _CountingBackend('probe-a');
      final host = _host({'backend.probe-a.enabled': true}, timers)
        ..registerBackend(backend);

      await host.enabledBackends();
      expect(backend.probeCount, 1);

      // Just inside the 30s TTL: still cached.
      timers.advance(const Duration(milliseconds: 29999));
      await host.enabledBackends();
      expect(backend.probeCount, 1);

      // Past the TTL: the invalidation fired, next call re-probes.
      timers.advance(const Duration(milliseconds: 2));
      await host.enabledBackends();
      expect(backend.probeCount, 2);
    });

    test('host.probe_cache_ttl_ms <= 0 disables caching', () async {
      final timers = FakeTimerFactory();
      final backend = _CountingBackend('probe-a');
      final host = _host({
        'backend.probe-a.enabled': true,
        'host.probe_cache_ttl_ms': 0,
      }, timers)..registerBackend(backend);

      await host.enabledBackends();
      await host.enabledBackends();
      expect(backend.probeCount, 2);
    });

    test('flag-off backend never probes (cache bypass)', () async {
      final timers = FakeTimerFactory();
      final backend = _CountingBackend('snap');
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _fedoraPlatform);
      final host = StoreHost(flags: flags, timerFactory: timers.call)
        ..registerBackend(backend);

      expect(await host.enabledBackends(), isEmpty);
      expect(backend.probeCount, 0);
    });

    test('cache is per backend id', () async {
      final timers = FakeTimerFactory();
      final down = _CountingBackend('probe-a', available: false);
      final up = _CountingBackend('probe-b', available: true);
      final host =
          _host({
              'backend.probe-a.enabled': true,
              'backend.probe-b.enabled': true,
            }, timers)
            ..registerBackend(down)
            ..registerBackend(up);

      // A's cached `false` must not leak onto B.
      expect((await host.enabledBackends()).map((b) => b.id), ['probe-b']);
      expect((await host.enabledBackends()).map((b) => b.id), ['probe-b']);
      expect(down.probeCount, 1);
      expect(up.probeCount, 1);
    });
  });
}
