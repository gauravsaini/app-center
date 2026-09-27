import 'package:app_center/store/store_host_wiring.dart';
import 'package:backend_appimage/testing.dart';
import 'package:backend_deb/testing.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_rpm/testing.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Debian-like platform for hermetic wiring tests: detection is skipped,
/// so the tests never read the machine's real /etc/os-release.
const _ubuntu = PlatformInfo(
  id: 'ubuntu',
  idLike: ['debian'],
  prettyName: 'Ubuntu 24.04 LTS',
);

/// Fedora-like platform: the §3 seed table turns snap+deb off.
const _fedora = PlatformInfo(
  id: 'fedora',
  idLike: [],
  prettyName: 'Fedora Linux',
);

void main() {
  tearDown(resetAllServices);

  test(
    'wiring: all three backend flags default on, one shared host and flag set',
    () {
      final container = createContainer();
      addTearDown(container.dispose);

      final flags = container.read(storeFlagsProvider);
      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.deb.enabled'), isTrue);

      // One instance per container: the catalog, flags, and engine are
      // shared, not rebuilt per widget.
      expect(
        identical(
          container.read(storeHostProvider),
          container.read(storeHostProvider),
        ),
        isTrue,
      );
      expect(
        identical(
          container.read(storeFlagsProvider),
          container.read(storeFlagsProvider),
        ),
        isTrue,
      );
    },
  );

  test(
    'wiring: stub-backed host registers snap+flatpak+deb, all available',
    () async {
      final flags = MapFeatureFlags();
      final host = buildStoreHost(
        flags,
        platformOverride: _ubuntu,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
        debTransport: StubPackageKitTransport(),
      );

      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.deb.enabled'), isTrue);

      final backends = await host.enabledBackends();
      expect(
        backends.map((b) => b.id).toList()..sort(),
        ['deb', 'flatpak', 'snap'],
      );
    },
  );

  test(
    'wiring: search flows Explore -> StoreHost -> stub backends',
    () async {
      final host = buildStoreHost(
        MapFeatureFlags(),
        platformOverride: _ubuntu,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
        debTransport: StubPackageKitTransport(),
      );

      final apps = await host.search('test').toList();
      final snapApps = apps.where(
        (a) => a.preferred.identity.backendId == 'snap',
      );
      expect(
        snapApps.map((a) => a.preferred.identity.nativeId),
        contains('test-snap'),
      );
      // Flatpak stub also answers search — the host fans out to all three.
      expect(
        apps.any((a) => a.preferred.identity.backendId == 'flatpak'),
        isTrue,
      );
      // Deb stub answers with its test package.
      final debApps = apps.where(
        (a) => a.preferred.identity.backendId == 'deb',
      );
      expect(
        debApps.map((a) => a.preferred.identity.nativeId),
        contains('test-deb'),
      );
    },
  );

  test(
    'wiring: real transports construct without touching the system',
    () {
      // Constructing must not connect: availability is checked lazily
      // per query by StoreHost.enabledBackends(), never here.
      // Detection runs against the real /etc/os-release here and never
      // throws — the worst case is PlatformInfo.unknown().
      final host = buildStoreHost(MapFeatureFlags());
      expect(host, isA<StoreHost>());
    },
  );

  test(
    'wiring: fedora-like platformOverride seeds snap+deb off, flatpak on',
    () async {
      final flags = MapFeatureFlags();
      final host = buildStoreHost(
        flags,
        platformOverride: _fedora,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
        debTransport: StubPackageKitTransport(),
        appimageTransport: StubAppimageTransport(),
      );

      // The §3 seed table: an apt/dpkg backend can never be honest on an
      // rpm system, and snapd is Ubuntu-canonical. Flatpak is
      // distro-agnostic (unchanged); appimage stays dogfooding-gated.
      // rpm is NOT auto-enabled on fedora-like systems — a separate,
      // deferred decision (rpm-backend-hld.md §5); default off holds.
      expect(flags.isEnabled('backend.snap.enabled'), isFalse);
      expect(flags.isEnabled('backend.deb.enabled'), isFalse);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.appimage.enabled'), isFalse);
      expect(flags.isEnabled('backend.rpm.enabled'), isFalse);

      final backends = await host.enabledBackends();
      expect(backends.map((b) => b.id).toList(), ['flatpak']);
    },
  );

  test(
    'wiring: rpm registered dark by default, flag-on surfaces it',
    () async {
      final flags = MapFeatureFlags();
      final host = buildStoreHost(
        flags,
        platformOverride: _fedora,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
        debTransport: StubPackageKitTransport(),
        appimageTransport: StubAppimageTransport(),
        rpmTransport: StubRpmTransport(),
      );

      // Ships dark on every platform until the fedora-like auto-enable
      // decision lands (rpm-backend-hld.md §5).
      expect(flags.isEnabled('backend.rpm.enabled'), isFalse);
      final dark = await host.enabledBackends();
      expect(dark.map((b) => b.id), isNot(contains('rpm')));

      // Operator flip: the registered backend answers flag reads and
      // probes like any other backend.
      flags.setFlag('backend.rpm.enabled', true);
      final backends = await host.enabledBackends();
      expect(backends.map((b) => b.id).toList(), ['flatpak', 'rpm']);
    },
  );

  test(
    'wiring: ubuntu platformOverride keeps today\'s defaults',
    () async {
      final flags = MapFeatureFlags();
      final host = buildStoreHost(
        flags,
        platformOverride: _ubuntu,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
        debTransport: StubPackageKitTransport(),
        appimageTransport: StubAppimageTransport(),
      );

      // Debian-like seeds exactly the compiled defaults.
      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.deb.enabled'), isTrue);

      final backends = await host.enabledBackends();
      expect(
        backends.map((b) => b.id).toList()..sort(),
        ['deb', 'flatpak', 'snap'],
      );
    },
  );

  test(
    'wiring: platform seeding happens before any backend flag read',
    () async {
      final flags = _RecordingFlags();
      final host = buildStoreHost(
        flags,
        platformOverride: _fedora,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
        debTransport: StubPackageKitTransport(),
        appimageTransport: StubAppimageTransport(),
      );

      // Drive flag reads through the host. StoreHost's constructor and
      // registerBackend() are lazy (no flag reads), so every read must
      // come after the seeding below.
      await host.enabledBackends();

      expect(
        flags.events.where((e) => e.startsWith('seed:')).toList(),
        ['seed:backend.snap.enabled', 'seed:backend.deb.enabled'],
      );
      final lastSeed = flags.events.lastIndexWhere(
        (e) => e.startsWith('seed:'),
      );
      final firstRead = flags.events.indexWhere(
        (e) => e.startsWith('read:'),
      );
      expect(firstRead, greaterThan(lastSeed));
    },
  );
}

/// Records [MapFeatureFlags.seedDefault] vs [MapFeatureFlags.isEnabled]
/// call order, to prove seeding precedes any backend flag read.
class _RecordingFlags extends MapFeatureFlags {
  final events = <String>[];

  @override
  void seedDefault(String key, Object value) {
    events.add('seed:$key');
    super.seedDefault(key, value);
  }

  @override
  bool isEnabled(String key) {
    events.add('read:$key');
    return super.isEnabled(key);
  }
}
