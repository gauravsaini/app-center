/// Probe-cache tests (docs/architecture/platform-detection.md §4).
///
/// Host-side `isAvailable()` memoization with a TTL from the
/// `host.probe_cache_ttl_ms` flag. Expiry is lazy: entries carry the
/// probe timestamp and a mutable fake [Clock] drives time forward —
/// no timers are ever armed, no real-time sleeps, no wall-clock reads.
library;

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

import 'stub_backends.dart';

/// Mutable fake wall clock.
class FakeClock {
  FakeClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration by) {
    now = now.add(by);
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

StoreHost _host(Map<String, Object> seed, FakeClock clock) {
  final flags = MapFeatureFlags(seed);
  return StoreHost(flags: flags, clock: clock.call);
}

const _fedoraPlatform = PlatformInfo(
  id: 'fedora',
  idLike: ['fedora'],
  prettyName: 'Fedora Linux',
);

void main() {
  group('probe cache', () {
    test('two enabledBackends() calls, TTL not expired -> one probe', () async {
      final clock = FakeClock(DateTime(2026, 9, 27));
      final backend = _CountingBackend('probe-a');
      final host = _host({'backend.probe-a.enabled': true}, clock)
        ..registerBackend(backend);

      expect((await host.enabledBackends()).map((b) => b.id), ['probe-a']);
      expect((await host.enabledBackends()).map((b) => b.id), ['probe-a']);
      expect(backend.probeCount, 1);
    });

    test('past the TTL the next call re-probes', () async {
      final clock = FakeClock(DateTime(2026, 9, 27));
      final backend = _CountingBackend('probe-a');
      final host = _host({'backend.probe-a.enabled': true}, clock)
        ..registerBackend(backend);

      await host.enabledBackends();
      expect(backend.probeCount, 1);

      // Just inside the 30s TTL: still cached.
      clock.advance(const Duration(milliseconds: 29999));
      await host.enabledBackends();
      expect(backend.probeCount, 1);

      // Past the TTL: the entry is stale, next call re-probes.
      clock.advance(const Duration(milliseconds: 2));
      await host.enabledBackends();
      expect(backend.probeCount, 2);
    });

    test('host.probe_cache_ttl_ms <= 0 disables caching', () async {
      final clock = FakeClock(DateTime(2026, 9, 27));
      final backend = _CountingBackend('probe-a');
      final host = _host({
        'backend.probe-a.enabled': true,
        'host.probe_cache_ttl_ms': 0,
      }, clock)..registerBackend(backend);

      await host.enabledBackends();
      await host.enabledBackends();
      expect(backend.probeCount, 2);
    });

    test('flag-off backend never probes (cache bypass)', () async {
      final clock = FakeClock(DateTime(2026, 9, 27));
      final backend = _CountingBackend('snap');
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _fedoraPlatform);
      final host = StoreHost(flags: flags, clock: clock.call)
        ..registerBackend(backend);

      expect(await host.enabledBackends(), isEmpty);
      expect(backend.probeCount, 0);
    });

    test('cache is per backend id', () async {
      final clock = FakeClock(DateTime(2026, 9, 27));
      final down = _CountingBackend('probe-a', available: false);
      final up = _CountingBackend('probe-b', available: true);
      final host =
          _host({
              'backend.probe-a.enabled': true,
              'backend.probe-b.enabled': true,
            }, clock)
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
