/// Widget tests for the deb search strangler-fig slice.
///
/// - flag on → deb results come from StoreHost (stub deb transport)
/// - flag off → legacy appstream path untouched
/// - deb backend unavailable → normal empty state, no crash
///
/// The install/remove action on the cards is covered separately in
/// unified_install_button_test.dart.
library;

import 'package:app_center/appstream/appstream.dart';
import 'package:app_center/search/search.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:backend_deb/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

void main() {
  tearDown(resetAllServices);

  StoreHost stubHost(MapFeatureFlags flags) => buildStoreHost(
    flags,
    debTransport: StubPackageKitTransport(),
  );

  Future<void> pumpDebSearch(
    WidgetTester tester, {
    required StoreHost host,
    required MapFeatureFlags flags,
    List<Override> extraOverrides = const [],
  }) {
    return tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
          packageFormatProvider.overrideWith((ref) => PackageFormat.deb),
          ...extraOverrides,
        ],
        child: const SearchPage(query: 'test'),
      ),
    );
  }

  testWidgets('flag on: deb search renders StoreHost results', (tester) async {
    final flags = MapFeatureFlags({'backend.deb.enabled': true});
    final host = stubHost(flags);

    await pumpDebSearch(tester, host: host, flags: flags);
    await tester.pumpAndSettle();

    // The deb stub's test package arrives via the unified search path.
    expect(find.text('test-deb'), findsOneWidget);
    expect(find.byType(AppCardGrid), findsOneWidget);
  });

  testWidgets('flag off: deb search keeps the legacy appstream path', (
    tester,
  ) async {
    final flags = MapFeatureFlags({'backend.deb.enabled': false});
    final host = stubHost(flags);

    await pumpDebSearch(
      tester,
      host: host,
      flags: flags,
      extraOverrides: [
        // Legacy path source: a component the unified path would never
        // produce (no deb backendId filtering involved).
        appstreamSearchProvider.overrideWith(
          (ref, query) => Stream.value([
            createAppstreamComponent(id: 'legacy-deb-id'),
          ]),
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Component'), findsOneWidget);
    expect(find.text('test-deb'), findsNothing);
  });

  testWidgets('flag on, deb backend unavailable: empty state, no crash', (
    tester,
  ) async {
    // Flags on but no stub transport: nothing registered, so the host
    // degrades to an empty search — never a crash.
    final flags = MapFeatureFlags({'backend.deb.enabled': true});
    final host = StoreHost(flags: flags);

    await pumpDebSearch(tester, host: host, flags: flags);
    await tester.pumpAndSettle();

    expect(
      find.text(tester.l10n.searchPageNoResults('test')),
      findsOneWidget,
    );
    expect(find.byType(AppCardGrid), findsNothing);
  });
}
