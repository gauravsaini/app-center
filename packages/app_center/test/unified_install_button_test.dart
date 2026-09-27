/// Widget tests for [UnifiedInstallButton].
///
/// Covers the host-routed operation seam on unified deb cards:
/// - permission line (ADR-009) renders before the action is enabled
/// - deb shows "Unsandboxed — full system access"
/// - install → live progress → Done
/// - cancel → back to idle
/// - installed deb offers Uninstall, routed through the host too
///
/// Never touches a real backend: the deb stub transport is scripted.
///
/// NOTE: these tests use explicit [WidgetTester.pump] calls with durations
/// instead of `pumpAndSettle` after an action starts. The in-flight UI shows
/// an indeterminate progress bar (infinite animation), which makes
/// `pumpAndSettle` unreliable — it can return before the scripted
/// transaction's timers fire.
library;

import 'dart:async';

import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:backend_deb/backend_deb.dart';
import 'package:backend_deb/testing.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'fake_inflight_handle.dart';
import 'test_utils.dart';

void main() {
  tearDown(resetAllServices);

  late StoreHost host;
  late UnifiedApp testDeb;

  setUp(() async {
    // All three backends stubbed: real transports would touch D-Bus /
    // snapd sockets that don't exist in tests.
    host = buildStoreHost(
      MapFeatureFlags(),
      snapTransport: StubSnapdTransport(),
      flatpakTransport: StubFlatpakTransport(),
      debTransport: StubPackageKitTransport(),
    );
    final apps = await host.search('test').toList();
    testDeb = apps.singleWhere(
      (a) =>
          a.preferred.identity ==
          const AppIdentity(
            backendId: 'deb',
            nativeId: 'test-deb',
          ),
    );
  });

  Future<void> pumpButton(WidgetTester tester, UnifiedApp app) {
    return tester.pumpApp(
      (_) => ProviderScope(
        overrides: [storeHostProvider.overrideWithValue(host)],
        child: Scaffold(body: UnifiedInstallButton(app: app)),
      ),
    );
  }

  /// Advances fake time past the stub's scripted transaction
  /// (6 events × 150ms) so it reaches its terminal state.
  Future<void> settleTransaction(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('permission shown before install is enabled', (tester) async {
    await pumpButton(tester, testDeb);
    await tester.pump(const Duration(milliseconds: 100));

    // ADR-009: permissions render adjacent to the action; the deb stub
    // reports the unsandboxed permission.
    expect(
      find.text('Unsandboxed — full system access'),
      findsOneWidget,
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNotNull,
    );
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('install runs through the host to Done', (tester) async {
    await pumpButton(tester, testDeb);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(OutlinedButton));
    await tester.pump(const Duration(milliseconds: 300));

    // Live operation: progress bar plus a cancel affordance.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.widgetWithIcon(IconButton, YaruIcons.stop),
      findsOneWidget,
    );

    await settleTransaction(tester);

    // Terminal Done: no crash, no flip back to Install.
    expect(find.byIcon(YaruIcons.ok), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('cancel returns the button to idle', (tester) async {
    await pumpButton(tester, testDeb);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(OutlinedButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithIcon(IconButton, YaruIcons.stop));
    await settleTransaction(tester);

    expect(find.text('Install'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('installed deb offers Uninstall through the host', (
    tester,
  ) async {
    final details = await host.getDetails(
      const AppIdentity(backendId: 'deb', nativeId: 'installed-deb'),
    );
    final installedDeb = UnifiedApp(
      groupId: 'deb:installed-deb',
      variants: [details.app],
    );
    expect(details.app.installedVersion, isNotNull);

    await pumpButton(tester, installedDeb);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Uninstall'), findsOneWidget);

    await tester.tap(find.byType(OutlinedButton));
    await settleTransaction(tester);

    expect(find.byIcon(YaruIcons.ok), findsOneWidget);
  });

  testWidgets('failed renders the localized reason; the error icon retries', (
    tester,
  ) async {
    // Drive the terminal outcome through the provider the way the host
    // does: handle present, then removed once terminal.
    final ops = StreamController<List<OperationHandle>>();
    addTearDown(ops.close);
    final handle = FakeInFlightHandle(app: testDeb.preferred.identity);
    addTearDown(handle.dispose);

    // The retry must not run the stub's scripted transaction: its fake
    // timers never drain in this harness. A recording transport that
    // throws a typed error proves the retry reaches the backend through
    // the host — the real-transaction path is covered by the tests above.
    final debTransport = _RecordingDeb();
    final retryHost = buildStoreHost(
      MapFeatureFlags(),
      snapTransport: StubSnapdTransport(),
      flatpakTransport: StubFlatpakTransport(),
      debTransport: debTransport,
    );

    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeHostProvider.overrideWithValue(retryHost),
          activeOperationsProvider.overrideWith((ref) => ops.stream),
        ],
        child: Scaffold(body: UnifiedInstallButton(app: testDeb)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    ops.add([handle]);
    await tester.pump();
    handle.emit(const Failed(error: NetworkException(debugDetail: 'boom')));
    await tester.pump();
    ops.add(const <OperationHandle>[]);
    await tester.pump();
    await tester.pump();

    // Reason line beside the error icon; debugDetail never leaks.
    expect(find.text(tester.l10n.operationFailureNetwork), findsOneWidget);
    expect(find.text('boom'), findsNothing);
    expect(find.widgetWithIcon(IconButton, YaruIcons.error), findsOneWidget);

    // Tapping the icon retries: the failure clears and the retry reaches
    // the backend through the host (the typed throw becomes a fresh
    // localized failure with the retry affordance intact).
    await tester.tap(find.widgetWithIcon(IconButton, YaruIcons.error));
    for (var i = 0; debTransport.installCalls == 0 && i < 20; i++) {
      await tester.pump();
    }
    expect(debTransport.installCalls, 1);
    // The typed throw lands a few microtasks after the transport records
    // the call; pump until the button renders the fresh failure.
    for (
      var i = 0;
      find
              .text(tester.l10n.operationFailureBackendUnavailable)
              .evaluate()
              .isEmpty &&
          i < 20;
      i++
    ) {
      await tester.pump();
    }
    expect(find.widgetWithIcon(IconButton, YaruIcons.error), findsOneWidget);
    expect(
      find.text(tester.l10n.operationFailureBackendUnavailable),
      findsOneWidget,
    );
  });
}

/// Records install attempts and throws a typed error: lets the button's
/// retry path prove it reaches the backend without running the stub's
/// scripted transaction (whose fake timers never drain in widget tests).
class _RecordingDeb extends StubPackageKitTransport {
  int installCalls = 0;

  @override
  Future<DebTransaction> install(String name) async {
    installCalls++;
    throw PackageKitTransportException('network unreachable');
  }
}
