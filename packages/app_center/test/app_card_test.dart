import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:app_center_ratings_client/app_center_ratings_client.dart';
import 'package:backend_deb/testing.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

const snapId = 'r4LxMVp7zWramXsJQAKdamxy6TAWlaDD';
const snapName = 'signal-desktop';
const snapRating = Rating(
  snapId: snapId,
  totalVotes: 123,
  ratingsBand: RatingsBand.good,
  snapName: snapName,
);

final snap = createSnap(
  name: 'testsnap',
  id: 'r4LxMVp7zWramXsJQAKdamxy6TAWlaDD',
  summary: 'Its a summary!',
);

void main() {
  setUp(() {
    registerMockSnapdService(storeSnap: snap);
    registerMockRatingsService(rating: snapRating, snapVotes: []);
  });
  tearDown(resetAllServices);

  testWidgets('query', (tester) async {
    await tester.pumpApp(
      (_) => ProviderScope(
        child: AppCard.fromSnap(snap: snap),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('testsnap'), findsOneWidget);
    expect(find.text(tester.l10n.snapRatingsBandGood), findsOneWidget);
    expect(
      find.text(' | ${tester.l10n.snapRatingsVotes(123)}'),
      findsOneWidget,
    );
  });

  /// Merged-card fixture: two variants of one canonical app.
  UnifiedApp mergedApp({int variantCount = 2}) {
    const variants = [
      AppInfo(
        identity: AppIdentity(backendId: 'snap', nativeId: 'test-snap'),
        name: 'Test App',
        summary: 'a test app',
        iconUrl: '',
        source: AppSource.snap,
        version: '1.0',
      ),
      AppInfo(
        identity: AppIdentity(backendId: 'deb', nativeId: 'test-deb'),
        name: 'Test App',
        summary: 'a test app',
        iconUrl: '',
        source: AppSource.deb,
        version: '2.0',
      ),
    ];
    return UnifiedApp(
      groupId: 'appstream:org.test.app',
      canonicalId: const CanonicalAppId(
        CanonicalIdScheme.appstream,
        'org.test.app',
      ),
      variants: variants.take(variantCount).toList(),
    );
  }

  /// The install button in the card footer needs a host; stub the
  /// transports so no D-Bus / snapd socket is touched.
  StoreHost stubHost() => buildStoreHost(
    MapFeatureFlags(),
    snapTransport: StubSnapdTransport(),
    flatpakTransport: StubFlatpakTransport(),
    debTransport: StubPackageKitTransport(),
  );

  Future<void> pumpUnifiedCard(
    WidgetTester tester, {
    required UnifiedApp app,
    bool identityFlag = false,
    VoidCallback? onTap,
  }) {
    return tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeHostProvider.overrideWithValue(stubHost()),
          if (identityFlag)
            storeFlagsProvider.overrideWithValue(
              MapFeatureFlags({'phase3.identity.enabled': true}),
            ),
        ],
        child: AppCard.fromUnifiedApp(app: app, onTap: onTap),
      ),
    );
  }

  testWidgets('merged app shows the formats chip when the flag is on', (
    tester,
  ) async {
    await pumpUnifiedCard(tester, app: mergedApp(), identityFlag: true);
    await tester.pumpAndSettle();

    // Still renders the preferred variant exactly as today...
    expect(find.text('Test App'), findsOneWidget);
    // ...plus the compact localized "N formats" affordance.
    expect(find.text(tester.l10n.unifiedAppFormatsChip(2)), findsOneWidget);
  });

  testWidgets('flag off: no formats chip on the card', (tester) async {
    await pumpUnifiedCard(tester, app: mergedApp());
    await tester.pumpAndSettle();

    expect(find.text('Test App'), findsOneWidget);
    expect(find.text(tester.l10n.unifiedAppFormatsChip(2)), findsNothing);
  });

  testWidgets('unresolved app: no formats chip even with the flag on', (
    tester,
  ) async {
    final unresolved = UnifiedApp(
      groupId: 'snap:test-snap',
      variants: mergedApp().variants.take(1).toList(),
    );
    await pumpUnifiedCard(tester, app: unresolved, identityFlag: true);
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.unifiedAppFormatsChip(1)), findsNothing);
  });

  testWidgets('single variant: no formats chip even with the flag on', (
    tester,
  ) async {
    await pumpUnifiedCard(
      tester,
      app: mergedApp(variantCount: 1),
      identityFlag: true,
    );
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.unifiedAppFormatsChip(1)), findsNothing);
  });

  testWidgets('formats chip opens the details page', (tester) async {
    var tapped = false;
    await pumpUnifiedCard(
      tester,
      app: mergedApp(),
      identityFlag: true,
      onTap: () => tapped = true,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(tester.l10n.unifiedAppFormatsChip(2)));
    expect(tapped, isTrue);
  });
}
