import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:app_center/manage/unified_manage_page.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Provider + page tests for the installed-listing result provider
/// (docs/architecture/parallel-installed.md):
///
/// - [unifiedInstalledProvider] is a projection over
///   [unifiedInstalledResultProvider] — one fetch serves both.
/// - Invalidation contract: refetch by invalidating
///   [unifiedInstalledResultProvider]; invalidating the projection alone
///   must NOT refetch.
/// - [UnifiedManagePage] shows the quiet partial caption when
///   [InstalledResult.isPartial] and hides it otherwise.
void main() {
  tearDown(resetAllServices);

  final apps = [
    _app('Firefox', AppSource.snap),
    _app('VLC', AppSource.deb),
  ];

  group('installed result provider', () {
    test('projection returns .apps; one host call serves both', () async {
      final host = _CountingStoreHost()
        ..result = InstalledResult(apps: apps, partialBackendIds: const []);
      final container = createContainer(
        overrides: [storeHostProvider.overrideWithValue(host)],
      );

      final projected = await container.read(unifiedInstalledProvider.future);
      // Reading the result provider joins the same in-flight fetch —
      // the host is listed exactly once for both reads.
      final result = await container.read(
        unifiedInstalledResultProvider.future,
      );

      expect(projected, apps);
      expect(result.apps, apps);
      expect(result.isPartial, isFalse);
      expect(host.installedDetailedCalls, 1);
    });

    test('partial ids flow through the result provider', () async {
      final host = _CountingStoreHost()
        ..result = InstalledResult(
          apps: apps,
          partialBackendIds: const ['deb'],
        );
      final container = createContainer(
        overrides: [storeHostProvider.overrideWithValue(host)],
      );

      final result = await container.read(
        unifiedInstalledResultProvider.future,
      );

      expect(result.isPartial, isTrue);
      expect(result.partialBackendIds, ['deb']);
      // The projection still serves the partial app list.
      expect(await container.read(unifiedInstalledProvider.future), apps);
    });

    test(
      'invalidating the projection alone does NOT refetch; invalidating '
      'the result provider refetches exactly once',
      () async {
        final host = _CountingStoreHost()
          ..result = InstalledResult(apps: apps, partialBackendIds: const []);
        final container = createContainer(
          overrides: [storeHostProvider.overrideWithValue(host)],
        );
        await container.read(unifiedInstalledProvider.future);
        expect(host.installedDetailedCalls, 1);

        // Invalidating the projection re-runs it against the result
        // provider's cached value — no new host call.
        container.invalidate(unifiedInstalledProvider);
        await container.read(unifiedInstalledProvider.future);
        expect(host.installedDetailedCalls, 1);

        // Invalidating the result provider refetches: exactly one fresh
        // installedDetailed() call, and the projection follows it.
        container.invalidate(unifiedInstalledResultProvider);
        await container.read(unifiedInstalledResultProvider.future);
        expect(host.installedDetailedCalls, 2);
        expect(
          await container.read(unifiedInstalledProvider.future),
          apps,
        );
      },
    );
  });

  group('partial caption', () {
    testWidgets('renders when a backend was excluded', (tester) async {
      await _pumpPage(
        tester,
        result: InstalledResult(
          apps: apps,
          partialBackendIds: const ['deb'],
        ),
      );

      expect(find.text('Firefox'), findsOneWidget);
      expect(
        find.text(tester.l10n.managePagePartialUpdatesCaption),
        findsOneWidget,
      );
    });

    testWidgets('absent when every backend answered', (tester) async {
      await _pumpPage(
        tester,
        result: InstalledResult(apps: apps, partialBackendIds: const []),
      );

      expect(find.text('Firefox'), findsOneWidget);
      expect(
        find.text(tester.l10n.managePagePartialUpdatesCaption),
        findsNothing,
      );
    });
  });
}

/// [StoreHost] fake that counts [installedDetailed] calls and returns a
/// scripted [InstalledResult].
class _CountingStoreHost extends StoreHost {
  _CountingStoreHost() : super(flags: MapFeatureFlags());

  int installedDetailedCalls = 0;
  InstalledResult result = const InstalledResult(
    apps: [],
    partialBackendIds: [],
  );

  @override
  Future<InstalledResult> installedDetailed() async {
    installedDetailedCalls++;
    return result;
  }
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required InstalledResult result,
}) async {
  await tester.pumpApp(
    (_) => ProviderScope(
      overrides: [
        unifiedInstalledResultProvider.overrideWith((ref) async => result),
        activeOperationsProvider.overrideWith(
          (ref) => const Stream<List<OperationHandle>>.empty(),
        ),
        // The tile's remove button reads details; keep it off the host.
        unifiedAppDetailsProvider.overrideWith(
          (ref, id) async => AppDetails(
            app: result.apps
                .map((a) => a.preferred)
                .firstWhere((info) => info.identity == id),
            description: 'Stub details.',
          ),
        ),
      ],
      child: const UnifiedManagePage(),
    ),
  );
  await tester.pumpAndSettle();
}

UnifiedApp _app(String name, AppSource source) => UnifiedApp(
  groupId: 'fake:$name',
  variants: [
    AppInfo(
      identity: AppIdentity(backendId: 'fake', nativeId: name),
      name: name,
      summary: 'A stub installed app.',
      iconUrl: '',
      source: source,
      installedVersion: '1.0',
    ),
  ],
);
