import 'package:app_center/manage/local_deb_updates_model.dart';
import 'package:app_center/ratings/ratings.dart';
import 'package:app_center/store/store_app.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtk/gtk.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'test_utils.dart';

/// Widget tests for the updates-badge strangler-fig slice: the Manage nav
/// tile's badge shows `unifiedUpdatesProvider`'s count when
/// `pages.updates.unified` is on, and the legacy snap/deb providers'
/// count otherwise (mirrors `unified_manage_page_test.dart` patterns).
void main() {
  tearDown(resetAllServices);

  group('flag off/absent: legacy nav badge', () {
    testWidgets('badge driven by snap/deb update providers', (tester) async {
      final snaps = [
        createSnap(name: 'firefox'),
        createSnap(name: 'thunderbird'),
      ];
      registerMockSnapdService(
        refreshableSnaps: snaps,
        installedSnaps: snaps,
      );
      registerMockService<GtkApplicationNotifier>(
        createMockGtkApplicationNotifier(),
      );
      registerMockService<RatingsService>(registerMockRatingsService());

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            // No `pages.updates.unified` key: absent means off.
            localDebUpdatesModelProvider.overrideWith(
              LocalDebUpdatesModel.new,
            ),
          ],
          child: const StoreApp(),
        ),
      );
      await tester.pumpAndSettle();

      final manageTile = find.widgetWithText(
        YaruMasterTile,
        tester.l10n.managePageLabel,
      );
      final badge = find.descendant(
        of: manageTile,
        matching: find.byType(Badge),
      );
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('2')),
        findsOneWidget,
      );
    });
  });

  group('flag on: unified nav badge', () {
    testWidgets('badge shows the unified update count', (tester) async {
      // Legacy sources report zero updates: the badge must come from the
      // unified path, not snapd.
      registerMockSnapdService();
      registerMockService<GtkApplicationNotifier>(
        createMockGtkApplicationNotifier(),
      );
      registerMockService<RatingsService>(registerMockRatingsService());

      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend([
            _update('fake.pkg1', 'Fake Package One'),
            _update('fake.pkg2', 'Fake Package Two'),
            _update('fake.pkg3', 'Fake Package Three'),
          ]),
        );

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const StoreApp(),
        ),
      );
      await tester.pumpAndSettle();

      final manageTile = find.widgetWithText(
        YaruMasterTile,
        tester.l10n.managePageLabel,
      );
      final badge = find.descendant(
        of: manageTile,
        matching: find.byType(Badge),
      );
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('3')),
        findsOneWidget,
      );
    });

    testWidgets('no badge while loading or when there are no updates', (
      tester,
    ) async {
      registerMockSnapdService();
      registerMockService<GtkApplicationNotifier>(
        createMockGtkApplicationNotifier(),
      );
      registerMockService<RatingsService>(registerMockRatingsService());

      // No backends: checkUpdates() is [] — same visual contract as
      // legacy (no badge for a zero count).
      final flags = MapFeatureFlags({'pages.updates.unified': true});
      final host = StoreHost(flags: flags);

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const StoreApp(),
        ),
      );
      await tester.pumpAndSettle();

      final manageTile = find.widgetWithText(
        YaruMasterTile,
        tester.l10n.managePageLabel,
      );
      expect(
        find.descendant(
          of: manageTile,
          matching: find.byType(Badge),
        ),
        findsNothing,
      );
    });
  });
}

UpdateInfo _update(String nativeId, String name) => UpdateInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
  fromVersion: '1.0',
  toVersion: '2.0',
);

/// Minimal backend stub whose only real behavior is [checkUpdates].
/// Everything else is a no-op — enough for the host fan-out.
class _StubUpdatesBackend extends StoreBackend {
  _StubUpdatesBackend(this._updates);

  final List<UpdateInfo> _updates;

  @override
  String get id => 'fake';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {BackendCapability.update};

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => const Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> install(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> remove(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> update(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<List<UpdateInfo>> checkUpdates() async => _updates;

  @override
  Future<List<AppInfo>> listInstalled() async => const [];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}
