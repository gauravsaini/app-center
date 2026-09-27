import 'dart:async';

import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:app_center/manage/unified_manage_page.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:ubuntu_widgets/ubuntu_widgets.dart';

import 'fake_inflight_handle.dart';
import 'test_utils.dart';

/// Widget tests for the unified Manage page polish: toolbar filtering and
/// sorting, pull-to-refresh, and the operation-terminal auto-refresh.
///
/// The host is faked at the provider boundary: [unifiedInstalledProvider]
/// is overridden with a call-counting closure (each invocation = one
/// `StoreHost.installed()` fan-out) and [activeOperationsProvider] with a
/// scripted stream. Debounces run on the test's fake clock.
void main() {
  tearDown(resetAllServices);

  final apps = [
    _app('Zulu App', AppSource.snap),
    _app('Alpha App', AppSource.deb),
    _app('Mike App', AppSource.flatpak),
  ];

  late int installedCalls;
  late StreamController<List<OperationHandle>> ops;

  setUp(() {
    installedCalls = 0;
    ops = StreamController<List<OperationHandle>>();
  });

  tearDown(() => ops.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    Duration refreshDebounce = const Duration(milliseconds: 100),
  }) async {
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          // Each invocation stands in for one StoreHost.installed() call.
          unifiedInstalledProvider.overrideWith((ref) async {
            installedCalls++;
            return apps;
          }),
          activeOperationsProvider.overrideWith((ref) => ops.stream),
          unifiedManageRefreshDebounceProvider.overrideWithValue(
            refreshDebounce,
          ),
          // The tile's remove button reads details; keep it off the host.
          unifiedAppDetailsProvider.overrideWith(
            (ref, id) async => AppDetails(
              app: apps
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

  double dy(WidgetTester tester, String name) =>
      tester.getCenter(find.text(name)).dy;

  group('toolbar', () {
    testWidgets('search narrows the tiles; clearing restores them', (
      tester,
    ) async {
      await pumpPage(tester);

      await tester.enterText(find.byType(TextFormField), 'zulu');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('Zulu App'), findsOneWidget);
      expect(find.text('Alpha App'), findsNothing);
      expect(find.text('Mike App'), findsNothing);

      await tester.enterText(find.byType(TextFormField), '');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('Zulu App'), findsOneWidget);
      expect(find.text('Alpha App'), findsOneWidget);
      expect(find.text('Mike App'), findsOneWidget);
    });

    testWidgets('source chip filters; All is selected by default', (
      tester,
    ) async {
      await pumpPage(tester);

      // Chips exist only for sources present in the list.
      expect(find.widgetWithText(FilterChip, 'All'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'snap'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'deb'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'flatpak'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'appImage'), findsNothing);

      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'All'))
            .selected,
        isTrue,
      );

      await tester.tap(find.widgetWithText(FilterChip, 'deb'));
      await tester.pumpAndSettle();

      expect(find.text('Alpha App'), findsOneWidget);
      expect(find.text('Zulu App'), findsNothing);
      expect(find.text('Mike App'), findsNothing);
    });

    testWidgets('sort menu reorders Z-A', (tester) async {
      await pumpPage(tester);

      // Default A-Z.
      expect(dy(tester, 'Alpha App') < dy(tester, 'Mike App'), isTrue);
      expect(dy(tester, 'Mike App') < dy(tester, 'Zulu App'), isTrue);

      await tester.tap(find.byType(MenuButtonBuilder<UnifiedManageSort>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name (Z–A)'));
      await tester.pumpAndSettle();

      expect(dy(tester, 'Zulu App') < dy(tester, 'Mike App'), isTrue);
      expect(dy(tester, 'Mike App') < dy(tester, 'Alpha App'), isTrue);
    });
  });

  group('refresh', () {
    testWidgets('pull-to-refresh refetches the installed list', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(installedCalls, 1);

      // Drag down past the overscroll threshold, then release: the
      // indicator fires onRefresh -> invalidate -> installed() again.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await gesture.moveBy(const Offset(0, 300));
      await tester.pump();
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await gesture.up();
      await tester.pump();
      // The indicator animates to full before firing onRefresh; advance
      // the fake clock past that animation, then let the refetch land.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(installedCalls, 2);
    });

    testWidgets('terminal operation triggers exactly one refetch', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(installedCalls, 1);

      final first = FakeInFlightHandle(
        app: apps[0].preferred.identity,
        kind: OperationKind.remove,
      );
      final second = FakeInFlightHandle(
        app: apps[1].preferred.identity,
        kind: OperationKind.update,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      // In-flight handles: no refetch yet.
      ops.add([first, second]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(installedCalls, 1);

      // Both vanish from the active list at once: the host dropped them
      // as terminal. The debounce coalesces them into a single refetch.
      ops.add(const <OperationHandle>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(installedCalls, 2);
    });

    testWidgets('progress event triggers no refetch', (tester) async {
      await pumpPage(tester);
      expect(installedCalls, 1);

      final handle = FakeInFlightHandle(
        app: apps[0].preferred.identity,
        kind: OperationKind.remove,
      );
      addTearDown(handle.dispose);

      ops.add([handle]);
      await tester.pump();
      // Non-terminal update; the host re-emits the active list.
      handle.emit(const Applying(fraction: 0.5));
      ops.add([handle]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(installedCalls, 1);
    });

    testWidgets('terminal during an in-flight fetch is skipped', (
      tester,
    ) async {
      // The installed future stays pending: the provider is loading.
      final gate = Completer<List<UnifiedApp>>();
      installedCalls = 0;
      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            unifiedInstalledProvider.overrideWith((ref) {
              installedCalls++;
              return gate.future;
            }),
            activeOperationsProvider.overrideWith((ref) => ops.stream),
            unifiedManageRefreshDebounceProvider.overrideWithValue(
              const Duration(milliseconds: 100),
            ),
          ],
          child: const UnifiedManagePage(),
        ),
      );
      await tester.pump();

      final handle = FakeInFlightHandle(
        app: apps[0].preferred.identity,
        kind: OperationKind.remove,
      );
      addTearDown(handle.dispose);
      ops.add([handle]);
      await tester.pump();
      ops.add(const <OperationHandle>[]);
      await tester.pump();
      // Debounce fires while the fetch is still in flight: the guard
      // must skip the invalidate (no refetch storm).
      await tester.pump(const Duration(milliseconds: 100));

      gate.complete(apps);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(installedCalls, 1);
    });
  });
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
