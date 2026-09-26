import 'package:app_center/search/search.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Widget tests for the search strangler-fig slice:
/// `SearchPage` -> `unifiedSnapSearchProvider` -> `StoreHost` -> backends.
void main() {
  setUp(registerMockRatingsService);
  tearDown(resetAllServices);

  StoreHost stubHost() => buildStoreHost(
    MapFeatureFlags(),
    snapTransport: StubSnapdTransport(),
    flatpakTransport: StubFlatpakTransport(),
  );

  testWidgets('flag on: snap results come from the unified store', (
    tester,
  ) async {
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeHostProvider.overrideWithValue(stubHost()),
        ],
        child: const SearchPage(query: 'test'),
      ),
    );
    await tester.pumpAndSettle();

    // StubSnapdTransport.find returns the scripted test snap.
    expect(find.text('Test Snap'), findsOneWidget);
    // Flatpak stub results are filtered out of the snap section.
    expect(find.text('Test App'), findsNothing);
    expect(find.byType(AppCardGrid), findsOneWidget);
  });

  testWidgets('flag off: falls back to the legacy snap search path', (
    tester,
  ) async {
    final mockSearchProvider = createMockSnapSearchProvider({
      const SnapSearchParameters(query: 'test'): [
        createSnap(name: 'legacy-snap', title: 'Legacy Snap'),
      ],
    });

    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(
            MapFeatureFlags({'backend.snap.enabled': false}),
          ),
          snapSearchProvider.overrideWith(
            (ref, params) => mockSearchProvider(params),
          ),
        ],
        child: const SearchPage(query: 'test'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Legacy Snap'), findsOneWidget);
    expect(find.text('Test Snap'), findsNothing);
  });

  testWidgets('flag on, backends unavailable: normal empty state, no crash', (
    tester,
  ) async {
    final flags = MapFeatureFlags({
      // Flags on, but no stub transport answers: every backend is
      // unavailable, so the host degrades to an empty search.
    });
    final host = StoreHost(flags: flags);
    // No backends registered at all: enabledBackends() is empty and the
    // search stream closes without results.

    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
        ],
        child: const SearchPage(query: 'test'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(tester.l10n.searchPageNoResults('test')),
      findsOneWidget,
    );
    expect(find.byType(AppCardGrid), findsNothing);
  });
}
