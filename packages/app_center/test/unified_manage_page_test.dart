import 'package:app_center/manage/local_deb_providers.dart';
import 'package:app_center/manage/local_deb_updates_model.dart';
import 'package:app_center/manage/manage.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Widget tests for the manage strangler-fig slice:
/// `ManagePage` -> `unifiedInstalledProvider` -> `StoreHost` -> backends,
/// gated by the `pages.manage.unified` flag.
void main() {
  tearDown(resetAllServices);

  group('flag off (default): legacy Manage page', () {
    setUp(() {
      registerMockSnapdService(
        installedSnaps: [
          createSnap(name: 'testsnap', title: 'Test Snap', version: '1.0'),
        ],
        // A non-empty updates list: the legacy page renders an invisible
        // but still-animating placeholder (maintainAnimation) in its
        // "no updates" branch, which would keep pumpAndSettle spinning.
        refreshableSnaps: [
          createSnap(
            name: 'testsnap3',
            title: 'Snap with an update',
            version: '2.0',
          ),
        ],
        changes: [],
      );
    });

    testWidgets('renders the legacy page, not the unified view', (
      tester,
    ) async {
      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            localDebsProvider.overrideWith((ref) async => []),
            localDebUpdatesModelProvider.overrideWith(
              LocalDebUpdatesModel.new,
            ),
            launchProvider.overrideWith(
              (_, __) => createMockSnapLauncher(),
            ),
          ],
          child: const ManagePage(),
        ),
      );
      await tester.pumpAndSettle();

      // Legacy markers: the check-for-updates action row only exists on
      // the legacy page.
      expect(
        find.text(tester.l10n.managePageCheckForUpdates),
        findsOneWidget,
      );
      expect(find.byType(UnifiedManagePage), findsNothing);
    });
  });

  group('flag on: unified installed list', () {
    testWidgets('renders canned installed apps from the host', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.manage.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubInstalledBackend([
            _installedApp('fake.app1', 'Fake App One', '1.0'),
            _installedApp('fake.app2', 'Fake App Two', '2.3'),
          ]),
        );

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const ManagePage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(UnifiedManagePage), findsOneWidget);
      expect(find.text('Fake App One'), findsOneWidget);
      expect(find.text('Fake App Two'), findsOneWidget);
      expect(find.text('1.0'), findsOneWidget);
      expect(find.text('2.3'), findsOneWidget);
      // One backend badge per row.
      expect(find.text('fake'), findsNWidgets(2));
      // Legacy action row stays out.
      expect(
        find.text(tester.l10n.managePageCheckForUpdates),
        findsNothing,
      );
    });

    testWidgets('empty installed list renders the empty state', (
      tester,
    ) async {
      final flags = MapFeatureFlags({'pages.manage.unified': true});
      // No backends registered at all: installed() is [].
      final host = StoreHost(flags: flags);

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const ManagePage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(UnifiedManagePage), findsOneWidget);
      expect(
        find.text(tester.l10n.unifiedManagePageEmptyTitle),
        findsOneWidget,
      );
      expect(
        find.text(tester.l10n.unifiedManagePageEmptyDescription),
        findsOneWidget,
      );
    });
  });
}

AppInfo _installedApp(String nativeId, String name, String version) => AppInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
  summary: 'A stub installed app.',
  iconUrl: '',
  source: AppSource.snap,
  version: version,
  installedVersion: version,
);

/// Minimal backend stub whose only real behavior is [listInstalled].
/// Everything else is a no-op — enough for the host fan-out.
class _StubInstalledBackend extends StoreBackend {
  _StubInstalledBackend(this._apps);

  final List<AppInfo> _apps;

  @override
  String get id => 'fake';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {
    BackendCapability.details,
    BackendCapability.remove,
  };

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => const Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    final app = _apps.where((a) => a.identity == id).firstOrNull;
    if (app == null) {
      throw AppNotFoundException(
        debugDetail: 'stub backend has no ${id.nativeId}',
        backendId: 'fake',
      );
    }
    // No permissions: the remove action enables immediately.
    return AppDetails(app: app, description: 'Stub details.');
  }

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
  Future<List<UpdateInfo>> checkUpdates() async => const [];

  @override
  Future<List<AppInfo>> listInstalled() async => _apps;

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}
