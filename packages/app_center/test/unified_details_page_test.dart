/// Widget tests for the unified details page strangler-fig slice.
///
/// - snap details render the confinement permission; deb details render
///   the unsandboxed permission
/// - the permissions section always renders above the install action
/// - one card per backend identity: multi-backend variants get a
///   switcher, never a merge
/// - tapping a unified snap/deb card navigates to the unified details
///   route; flag-off keeps the legacy snap details navigation
/// - update action enqueues a host update when the app reports one
///
/// Never touches a real backend: all transports are stubbed.
library;

import 'dart:io';

import 'package:app_center/details/details.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/search/search.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:backend_deb/testing.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'test_utils.dart';

void main() {
  setUp(registerMockRatingsService);
  tearDown(resetAllServices);

  // All three backends stubbed: real transports would touch D-Bus /
  // snapd sockets that don't exist in tests.
  StoreHost stubHost() => buildStoreHost(
    MapFeatureFlags(),
    snapTransport: StubSnapdTransport(),
    flatpakTransport: StubFlatpakTransport(),
    debTransport: StubPackageKitTransport(),
  );

  Future<void> pumpDetails(
    WidgetTester tester, {
    required AppIdentity identity,
    UnifiedApp? app,
  }) {
    return tester.pumpApp(
      (_) => ProviderScope(
        overrides: [storeHostProvider.overrideWithValue(stubHost())],
        child: UnifiedDetailsPage(identity: identity, app: app),
      ),
    );
  }

  testWidgets('snap details show the confinement permission', (tester) async {
    await pumpDetails(
      tester,
      identity: const AppIdentity(backendId: 'snap', nativeId: 'test-snap'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Snap'), findsOneWidget);
    expect(find.text('Snap'), findsOneWidget); // backend badge
    expect(
      find.text('Sandboxed (strict confinement)'),
      findsWidgets,
    );
    expect(
      find.text('A longer description of the test snap.'),
      findsOneWidget,
    );
  });

  testWidgets('deb details show the unsandboxed permission', (tester) async {
    await pumpDetails(
      tester,
      identity: const AppIdentity(backendId: 'deb', nativeId: 'test-deb'),
    );
    await tester.pumpAndSettle();

    expect(find.text('test-deb'), findsOneWidget);
    expect(find.text('Deb'), findsOneWidget); // backend badge
    expect(
      find.text('Unsandboxed — full system access'),
      findsWidgets,
    );
  });

  testWidgets('permissions render above the install action', (tester) async {
    await pumpDetails(
      tester,
      identity: const AppIdentity(backendId: 'snap', nativeId: 'test-snap'),
    );
    await tester.pumpAndSettle();

    // The permissions *section* (first match) sits above the install
    // button; the button's own ADR-009 permission line is the second.
    final sectionDy = tester
        .getTopLeft(find.text('Sandboxed (strict confinement)').first)
        .dy;
    final installDy = tester
        .getTopLeft(find.text(tester.l10n.snapActionInstallLabel).first)
        .dy;
    expect(sectionDy, lessThan(installDy));
  });

  testWidgets('multi-backend variants get a switcher, never a merge', (
    tester,
  ) async {
    const snapId = AppIdentity(backendId: 'snap', nativeId: 'test-snap');
    const debId = AppIdentity(backendId: 'deb', nativeId: 'test-deb');
    final app = UnifiedApp(
      groupId: 'test-snap',
      variants: const [
        AppInfo(
          identity: snapId,
          name: 'Test Snap',
          summary: 'a test snap',
          iconUrl: '',
          source: AppSource.snap,
          version: '1.0',
        ),
        AppInfo(
          identity: debId,
          name: 'test-deb',
          summary: 'a test deb',
          iconUrl: '',
          source: AppSource.deb,
          version: '1.0',
        ),
      ],
    );

    await pumpDetails(tester, identity: snapId, app: app);
    await tester.pumpAndSettle();

    // Both formats listed separately — the switcher, not a merged card.
    expect(
      find.text(tester.l10n.unifiedDetailsOtherFormatsLabel),
      findsOneWidget,
    );
    expect(find.text('Sandboxed (strict confinement)'), findsWidgets);

    await tester.tap(find.text('Deb'));
    await tester.pumpAndSettle();

    // Switching swaps the whole card: permissions, name, badge.
    expect(find.text('Unsandboxed — full system access'), findsWidgets);
    expect(find.text('test-deb'), findsOneWidget);
    expect(find.text('Sandboxed (strict confinement)'), findsNothing);
  });

  testWidgets('single-variant app shows no switcher', (tester) async {
    await pumpDetails(
      tester,
      identity: const AppIdentity(backendId: 'deb', nativeId: 'test-deb'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(tester.l10n.unifiedDetailsOtherFormatsLabel),
      findsNothing,
    );
  });

  /// Pumps [SearchPage] inside a route-recording app, taps [tapText],
  /// and returns every pushed route name.
  Future<List<String>> pumpSearchAndTap(
    WidgetTester tester, {
    required String tapText,
    required List<Override> overrides,
  }) async {
    final pushed = <String>[];
    // Same viewport and font as pumpApp: the search header row overflows
    // at the default test size/font.
    tester.view.physicalSize =
        (const Size(800, 600) + const Offset(54, 54)) *
        tester.view.devicePixelRatio;
    final ubuntuRegular = File('test/fonts/Ubuntu-Regular.ttf');
    final content = ByteData.view(
      Uint8List.fromList(ubuntuRegular.readAsBytesSync()).buffer,
    );
    final fontLoader = FontLoader('UbuntuRegular')
      ..addFont(Future.value(content));
    await fontLoader.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'UbuntuRegular'),
        localizationsDelegates: localizationsDelegates,
        onGenerateRoute: (settings) {
          pushed.add(settings.name ?? '');
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => const SizedBox(),
          );
        },
        home: Scaffold(
          body: Builder(
            builder: (_) => ProviderScope(
              overrides: overrides,
              child: const SearchPage(query: 'test'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(tapText));
    await tester.pumpAndSettle();
    return pushed;
  }

  testWidgets('tapping a unified snap card opens the unified details page', (
    tester,
  ) async {
    final pushed = await pumpSearchAndTap(
      tester,
      tapText: 'Test Snap',
      overrides: [storeHostProvider.overrideWithValue(stubHost())],
    );

    expect(
      pushed.any(
        (r) =>
            r.contains(StoreRoutes.unifiedDetails) &&
            r.contains('backend=snap') &&
            r.contains('nativeId=test-snap'),
      ),
      isTrue,
    );
  });

  testWidgets('tapping a unified deb card opens the unified details page', (
    tester,
  ) async {
    final pushed = await pumpSearchAndTap(
      tester,
      tapText: 'test-deb',
      overrides: [
        storeHostProvider.overrideWithValue(stubHost()),
        packageFormatProvider.overrideWith((ref) => PackageFormat.deb),
      ],
    );

    expect(
      pushed.any(
        (r) =>
            r.contains(StoreRoutes.unifiedDetails) &&
            r.contains('backend=deb') &&
            r.contains('nativeId=test-deb'),
      ),
      isTrue,
    );
  });

  testWidgets('flag off: snap card keeps the legacy details navigation', (
    tester,
  ) async {
    final mockSearchProvider = createMockSnapSearchProvider({
      const SnapSearchParameters(query: 'test'): [
        createSnap(name: 'legacy-snap', title: 'Legacy Snap'),
      ],
    });

    final pushed = await pumpSearchAndTap(
      tester,
      tapText: 'Legacy Snap',
      overrides: [
        storeFlagsProvider.overrideWithValue(
          MapFeatureFlags({'backend.snap.enabled': false}),
        ),
        snapSearchProvider.overrideWith(
          (ref, params) => mockSearchProvider(params),
        ),
      ],
    );

    expect(
      pushed.any((r) => r.startsWith('${StoreRoutes.snap}?')),
      isTrue,
    );
    expect(
      pushed.any((r) => r.contains(StoreRoutes.unifiedDetails)),
      isFalse,
    );
  });

  testWidgets('update action enqueues a host update', (tester) async {
    final host = stubHost();
    const app = UnifiedApp(
      groupId: 'deb:installed-deb',
      variants: [
        AppInfo(
          identity: AppIdentity(backendId: 'deb', nativeId: 'installed-deb'),
          name: 'installed-deb',
          summary: 'an installed deb',
          iconUrl: '',
          source: AppSource.deb,
          version: '2.1',
          installedVersion: '2.0',
          updateAvailable: true,
        ),
      ],
    );

    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [storeHostProvider.overrideWithValue(host)],
        child: const Scaffold(body: UnifiedInstallButton(app: app)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Installed + update available → Update, not Uninstall.
    expect(
      find.text(tester.l10n.unifiedDetailsUpdateLabel),
      findsOneWidget,
    );

    await tester.tap(find.text(tester.l10n.unifiedDetailsUpdateLabel));
    await tester.pump(const Duration(milliseconds: 300));

    // Live operation through the host: progress + cancel.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.widgetWithIcon(IconButton, YaruIcons.stop),
      findsOneWidget,
    );

    // Drain the scripted transaction so no timers are pending at teardown.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byIcon(YaruIcons.ok), findsOneWidget);
  });
}
