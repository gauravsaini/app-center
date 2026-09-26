import 'package:app_center/store/store_host_wiring.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

void main() {
  tearDown(resetAllServices);

  test(
    'wiring: both backend flags default on, one shared host and flag set',
    () {
      final container = createContainer();
      addTearDown(container.dispose);

      final flags = container.read(storeFlagsProvider);
      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);

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
    'wiring: stub-backed host registers snap+flatpak, both available',
    () async {
      final flags = MapFeatureFlags();
      final host = buildStoreHost(
        flags,
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
      );

      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);

      final backends = await host.enabledBackends();
      expect(
        backends.map((b) => b.id).toList()..sort(),
        ['flatpak', 'snap'],
      );
    },
  );

  test(
    'wiring: search flows Explore -> StoreHost -> stub backends',
    () async {
      final host = buildStoreHost(
        MapFeatureFlags(),
        snapTransport: StubSnapdTransport(),
        flatpakTransport: StubFlatpakTransport(),
      );

      final apps = await host.search('test').toList();
      final snapApps = apps.where(
        (a) => a.preferred.identity.backendId == 'snap',
      );
      expect(
        snapApps.map((a) => a.preferred.identity.nativeId),
        contains('test-snap'),
      );
      // Flatpak stub also answers search — the host fans out to both.
      expect(
        apps.any((a) => a.preferred.identity.backendId == 'flatpak'),
        isTrue,
      );
    },
  );

  test(
    'wiring: real transports construct without touching the system',
    () {
      // Constructing must not connect: availability is checked lazily
      // per query by StoreHost.enabledBackends(), never here.
      final host = buildStoreHost(MapFeatureFlags());
      expect(host, isA<StoreHost>());
    },
  );
}
