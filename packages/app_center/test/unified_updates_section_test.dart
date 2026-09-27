import 'package:app_center/error/error.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/manage/local_deb_providers.dart';
import 'package:app_center/manage/local_deb_updates_model.dart';
import 'package:app_center/manage/local_snap_providers.dart';
import 'package:app_center/manage/manage.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:app_center/widgets/operation_inflight_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:ubuntu_widgets/ubuntu_widgets.dart';
import 'package:yaru/yaru.dart';

import 'fake_inflight_handle.dart';
import 'test_utils.dart';

/// Widget tests for the updates strangler-fig slice:
/// `ManagePage` -> `unifiedUpdatesProvider` -> `StoreHost` ->
/// backends, gated by the `pages.updates.unified` flag.
void main() {
  tearDown(resetAllServices);

  group('flag on: unified updates section', () {
    testWidgets('renders one row per update with version text', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend(
            updates: [
              _update('fake.app1', 'Fake App One', '1.0', '2.0'),
              _update('fake.app2', 'Fake App Two', null, '3.1'),
            ],
          ),
        );

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const CustomScrollView(
            slivers: [UnifiedUpdatesSection()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Header shows the update count, like the legacy section.
      expect(
        find.text(tester.l10n.managePageUpdatesAvailable(2)),
        findsOneWidget,
      );
      // One row per UpdateInfo: name + from → to.
      expect(find.text('Fake App One'), findsOneWidget);
      expect(find.text('Fake App Two'), findsOneWidget);
      expect(find.text('1.0 → 2.0'), findsOneWidget);
      expect(find.text('3.1'), findsOneWidget);
      // One backend badge per row.
      expect(find.text('fake'), findsNWidgets(2));
      // Update-all action present.
      expect(
        find.text(tester.l10n.managePageUpdateAllLabel),
        findsOneWidget,
      );
    });

    testWidgets('update-all enqueues one update op per UpdateInfo', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final backend = _StubUpdatesBackend(
        updates: [
          _update('fake.app1', 'Fake App One', '1.0', '2.0'),
          _update('fake.app2', 'Fake App Two', '2.3', '2.4'),
        ],
      );
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const CustomScrollView(
            slivers: [UnifiedUpdatesSection()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final checksBefore = backend.checkUpdatesCalls;
      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await tester.pumpAndSettle();

      // Exactly one host update per UpdateInfo identity, in order.
      expect(
        backend.updatedIdentities,
        [
          const AppIdentity(backendId: 'fake', nativeId: 'fake.app1'),
          const AppIdentity(backendId: 'fake', nativeId: 'fake.app2'),
        ],
      );
      // The provider is invalidated after the batch completes.
      expect(backend.checkUpdatesCalls, greaterThan(checksBefore));
    });

    testWidgets('row with in-flight handle renders progress + cancel', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      const inFlightId = AppIdentity(
        backendId: 'fake',
        nativeId: 'fake.app1',
      );
      final handle = FakeInFlightHandle(
        app: inFlightId,
        kind: OperationKind.update,
      );
      addTearDown(handle.dispose);
      handle.emit(const Downloading(bytesDone: 3, bytesTotal: 10));
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend(
            updates: [
              _update('fake.app1', 'Fake App One', '1.0', '2.0'),
              _update('fake.app2', 'Fake App Two', null, '3.1'),
            ],
          ),
        );

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
            // The row self-matches its non-terminal handle out of the
            // provider by UpdateInfo.identity (LLD §8).
            activeOperationsProvider.overrideWith(
              (ref) => Stream.value(<OperationHandle>[handle]),
            ),
          ],
          child: const CustomScrollView(
            slivers: [UnifiedUpdatesSection()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Only the row whose identity matches renders the in-flight
      // controls, with the scripted determinate progress.
      expect(find.byType(OperationInFlightControls), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.3,
      );
      // The other row is unaffected.
      expect(find.text('Fake App Two'), findsOneWidget);

      // Cancel dispatch reaches the handle; the caption lands.
      await tester.tap(find.widgetWithIcon(IconButton, YaruIcons.stop));
      await tester.pump();
      expect(handle.cancelCallCount, 1);
      expect(
        find.text(tester.l10n.snapActionCancellingLabel),
        findsOneWidget,
      );
    });

    testWidgets('row without an in-flight handle renders as before', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend(
            updates: [_update('fake.app1', 'Fake App One', '1.0', '2.0')],
          ),
        );

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
            activeOperationsProvider.overrideWith(
              (ref) => Stream.value(const <OperationHandle>[]),
            ),
          ],
          child: const CustomScrollView(
            slivers: [UnifiedUpdatesSection()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No handle: no progress controls, row content unchanged.
      expect(find.byType(OperationInFlightControls), findsNothing);
      expect(find.text('Fake App One'), findsOneWidget);
      expect(find.text('1.0 → 2.0'), findsOneWidget);
      expect(find.text('fake'), findsOneWidget);
    });

    testWidgets('empty updates render the empty state', (tester) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(_StubUpdatesBackend(updates: const []));

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const CustomScrollView(
            slivers: [UnifiedUpdatesSection()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(tester.l10n.managePageNoUpdatesAvailableDescription),
        findsOneWidget,
      );
      // Update-all is disabled with nothing to update.
      final button = tester.widget<PushButton>(
        find.ancestor(
          of: find.text(tester.l10n.managePageUpdateAllLabel),
          matching: find.byWidgetPredicate((w) => w is PushButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('checkUpdates error renders ErrorView with retry', (
      tester,
    ) async {
      // Note: the host itself never throws (per-backend degradation),
      // so the error state is exercised by failing the provider above
      // the host — exactly the case its doc comment describes.
      var shouldThrow = true;
      final flags = MapFeatureFlags({'pages.updates.unified': true});

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            unifiedUpdatesProvider.overrideWith((ref) async {
              if (shouldThrow) throw Exception('boom');
              return [_update('fake.app1', 'Fake App One', '1.0', '2.0')];
            }),
          ],
          child: const CustomScrollView(
            slivers: [UnifiedUpdatesSection()],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsOneWidget);

      // Retry invalidates the provider: the section recovers.
      // ErrorView renders retry first, checkStatus second.
      shouldThrow = false;
      await tester.tap(find.byType(OutlinedButton).first);
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('Fake App One'), findsOneWidget);
    });
  });

  group('per-row failure display', () {
    /// Scriptable backend + per-identity handle registry for driving
    /// per-row terminal outcomes through the real host. [updated]
    /// records the identities the backend's update() actually ran for
    /// (enqueue-thrown calls never reach it).
    ({
      _StubUpdatesBackend backend,
      Map<AppIdentity, FakeInFlightHandle> handles,
      List<AppIdentity> updated,
    })
    scriptable(
      List<UpdateInfo> updates, {
      Set<AppIdentity> throwOnUpdate = const {},
    }) {
      final handles = <AppIdentity, FakeInFlightHandle>{};
      final updated = <AppIdentity>[];
      final backend = _StubUpdatesBackend(
        updates: updates,
        updateOverride: (id) async {
          if (throwOnUpdate.contains(id)) {
            throw const BackendUnavailableException(
              debugDetail: 'backend-gone-debug',
              backendId: 'fake',
            );
          }
          updated.add(id);
          final handle = FakeInFlightHandle(
            app: id,
            kind: OperationKind.update,
          );
          handles[id] = handle;
          addTearDown(handle.dispose);
          return handle;
        },
      );
      return (backend: backend, handles: handles, updated: updated);
    }

    MapFeatureFlags testFlags() => MapFeatureFlags({
      'pages.updates.unified': true,
      'backend.fake.enabled': true,
    });

    Future<void> pumpSection(
      WidgetTester tester,
      StoreHost host,
      MapFeatureFlags flags, {
      List<Override> extraOverrides = const [],
    }) => tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
          ...extraOverrides,
        ],
        child: const CustomScrollView(
          slivers: [UnifiedUpdatesSection()],
        ),
      ),
    );

    String retryLabel(WidgetTester tester) => UbuntuLocalizations.of(
      tester.element(find.byType(UnifiedUpdatesSection)),
    ).retryLabel;

    /// Pumps until the backend has enqueued [id] AND the row has
    /// observed the handle (in-flight controls rendered). Both are
    /// required before driving the handle terminal: the host reports
    /// terminal by *removing* the handle from the active list, and the
    /// row only records the outcome when its `_lastHandle` saw the
    /// handle first (a removal the row never saw is lost — the
    /// provider's broadcast stream does not replay).
    Future<void> waitForRowInflight(
      WidgetTester tester,
      Map<AppIdentity, FakeInFlightHandle> handles,
      AppIdentity id,
    ) async {
      for (var i = 0; handles[id] == null && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(handles[id], isNotNull, reason: 'backend never enqueued $id');
      for (
        var i = 0;
        find.byType(OperationInFlightControls).evaluate().isEmpty && i < 100;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        find.byType(OperationInFlightControls),
        findsWidgets,
        reason: 'row never observed the in-flight handle',
      );
    }

    /// Pumps until the row has recorded its terminal outcome.
    Future<void> waitForText(WidgetTester tester, String text) async {
      for (var i = 0; find.text(text).evaluate().isEmpty && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text(text), findsOneWidget);
    }

    const app1Id = AppIdentity(backendId: 'fake', nativeId: 'fake.app1');
    const app2Id = AppIdentity(backendId: 'fake', nativeId: 'fake.app2');

    testWidgets('failed row renders reason + retry; retry re-enqueues once', (
      tester,
    ) async {
      final flags = testFlags();
      final (:backend, :handles, :updated) = scriptable([
        _update('fake.app1', 'Fake App One', '1.0', '2.0'),
      ]);
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await pumpSection(tester, host, flags);
      await tester.pumpAndSettle();

      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(
        const Failed(error: NetworkException(debugDetail: 'boom')),
      );
      await waitForText(tester, tester.l10n.operationFailureNetwork);

      // Row shows the localized reason + retry; debugDetail never leaks.
      expect(find.text('boom'), findsNothing);
      expect(find.byIcon(YaruIcons.error), findsOneWidget);
      final retry = find.widgetWithText(TextButton, retryLabel(tester));
      expect(retry, findsOneWidget);

      // Retry re-enqueues exactly once (update-all's 1 + retry's 1).
      await tester.tap(retry);
      await waitForRowInflight(tester, handles, app1Id);
      expect(updated.where((i) => i == app1Id), hasLength(2));

      // The fresh handle is in flight: progress replaces the retry, so a
      // second tap is impossible...
      expect(find.byType(OperationInFlightControls), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);

      // ...and the host dedupes anyway: a second enqueue while
      // non-terminal adds no new work (the host contract is pinned in
      // store_host's host_test; this widget only asserts the
      // user-observable outcome).
      await host.enqueue(OperationKind.update, app1Id);
      await host.enqueue(OperationKind.update, app1Id);
      expect(updated.where((i) => i == app1Id), hasLength(2));

      // Settle the retried op.
      handles[app1Id]!.emit(const Done(result: OperationResult()));
      await tester.pumpAndSettle();
      expect(find.byIcon(YaruIcons.ok), findsOneWidget);
    });

    testWidgets('enqueue-thrown StoreException renders as failed', (
      tester,
    ) async {
      final flags = testFlags();
      final throwing = <AppIdentity>{};
      final (:backend, :handles, :updated) = scriptable(
        [_update('fake.app1', 'Fake App One', '1.0', '2.0')],
        throwOnUpdate: throwing,
      );
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await pumpSection(tester, host, flags);
      await tester.pumpAndSettle();

      // First failure is handle-driven so the row gains a retry.
      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(
        const Failed(error: NetworkException(debugDetail: 'boom')),
      );
      await waitForText(tester, tester.l10n.operationFailureNetwork);

      // Now the backend is gone: retry's enqueue throws, surfacing as a
      // local Failed. BackendUnavailableException is fixBackend, so the
      // row shows error icon + reason with no retry affordance
      // (per-row-failure HLD §3 table + §7, normative).
      throwing.add(app1Id);
      await tester.tap(find.widgetWithText(TextButton, retryLabel(tester)));
      await tester.pumpAndSettle();
      expect(
        find.text(tester.l10n.operationFailureBackendUnavailable),
        findsOneWidget,
      );
      expect(find.text('backend-gone-debug'), findsNothing);
      expect(find.byIcon(YaruIcons.error), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      // The throwing enqueue never reached the backend's update.
      expect(updated.where((i) => i == app1Id), hasLength(1));
    });

    testWidgets('watchdog timeout failure renders the stalled reason', (
      tester,
    ) async {
      final flags = testFlags();
      final (:backend, :handles, :updated) = scriptable([
        _update('fake.app1', 'Fake App One', '1.0', '2.0'),
      ]);
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await pumpSection(tester, host, flags);
      await tester.pumpAndSettle();

      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(
        const Failed(
          error: TimeoutException(
            debugDetail: 'watchdog-debug',
            stalledPhase: 'Applying',
          ),
        ),
      );
      await waitForText(tester, tester.l10n.operationFailureTimeout);
      expect(find.text('watchdog-debug'), findsNothing);
      // stalledPhase is debug vocabulary, never user vocabulary.
      expect(find.text('Applying'), findsNothing);
      expect(find.byIcon(YaruIcons.error), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, retryLabel(tester)),
        findsOneWidget,
      );
    });

    testWidgets('auth-denied renders a quiet neutral note', (tester) async {
      final flags = testFlags();
      final (:backend, :handles, :updated) = scriptable([
        _update('fake.app1', 'Fake App One', '1.0', '2.0'),
      ]);
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await pumpSection(tester, host, flags);
      await tester.pumpAndSettle();

      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(
        const Failed(
          error: AuthException(debugDetail: 'denied-debug'),
        ),
      );
      await waitForText(tester, tester.l10n.operationFailureAuthDenied);

      // Quiet note: reason text, but no retry and no error styling —
      // remediation == none means nothing the user can do.
      final reason = find.text(tester.l10n.operationFailureAuthDenied);
      expect(reason, findsOneWidget);
      expect(find.text('denied-debug'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byIcon(YaruIcons.error), findsNothing);
      expect(
        tester.widget<Text>(reason).style?.color,
        isNot(
          Theme.of(
            tester.element(find.byType(UnifiedUpdatesSection)),
          ).colorScheme.error,
        ),
      );
    });

    testWidgets('cancelled returns the row to idle', (tester) async {
      final flags = testFlags();
      final (:backend, :handles, :updated) = scriptable([
        _update('fake.app1', 'Fake App One', '1.0', '2.0'),
      ]);
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await pumpSection(tester, host, flags);
      await tester.pumpAndSettle();

      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(const Cancelled());
      await tester.pumpAndSettle();

      // Quiet return to the pre-action row: no icon, no note.
      expect(find.byIcon(YaruIcons.error), findsNothing);
      expect(find.byIcon(YaruIcons.ok), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.text('Fake App One'), findsOneWidget);
      expect(find.text('1.0 → 2.0'), findsOneWidget);
    });

    testWidgets('done renders ok; done-after-cancel adds the neutral note', (
      tester,
    ) async {
      final flags = testFlags();
      final (:backend, :handles, :updated) = scriptable([
        _update('fake.app1', 'Fake App One', '1.0', '2.0'),
        _update('fake.app2', 'Fake App Two', '2.3', '2.4'),
      ]);
      final host = StoreHost(flags: flags)..registerBackend(backend);

      await pumpSection(tester, host, flags);
      await tester.pumpAndSettle();

      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(
        const Done(result: OperationResult(cancelRequested: true)),
      );
      // The loop enqueues app2 only after app1 reaches terminal.
      await waitForRowInflight(tester, handles, app2Id);
      handles[app2Id]!.emit(const Done(result: OperationResult()));
      await tester.pumpAndSettle();

      expect(find.byIcon(YaruIcons.ok), findsNWidgets(2));
      expect(
        find.text(tester.l10n.operationDoneAfterCancelNote),
        findsOneWidget,
      );
      expect(find.byIcon(YaruIcons.error), findsNothing);
    });

    testWidgets(
      'per-row retry disabled while update-all runs; '
      'new batch clears stale failures',
      (tester) async {
        final flags = testFlags();
        final (:backend, :handles, :updated) = scriptable([
          _update('fake.app1', 'Fake App One', '1.0', '2.0'),
          _update('fake.app2', 'Fake App Two', '2.3', '2.4'),
        ]);
        final host = StoreHost(flags: flags)..registerBackend(backend);

        await pumpSection(tester, host, flags);
        await tester.pumpAndSettle();

        // Batch 1: app1 fails fast while app2 hangs — the failure is
        // visible while _updatingAll is still true.
        await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
        await waitForRowInflight(tester, handles, app1Id);
        handles[app1Id]!.emit(
          const Failed(error: NetworkException(debugDetail: 'boom')),
        );
        await waitForText(tester, tester.l10n.operationFailureNetwork);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, retryLabel(tester)),
              )
              .onPressed,
          isNull,
        );

        // Batch 1 ends when app2 completes; the retry enables.
        await waitForRowInflight(tester, handles, app2Id);
        handles[app2Id]!.emit(const Done(result: OperationResult()));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, retryLabel(tester)),
              )
              .onPressed,
          isNotNull,
        );

        // Batch 2 starts: the stale failure clears at batch start.
        await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
        await waitForRowInflight(tester, handles, app1Id);
        expect(
          find.text(tester.l10n.operationFailureNetwork),
          findsNothing,
        );

        // Settle batch 2.
        handles[app1Id]!.emit(const Done(result: OperationResult()));
        // The loop enqueues app2 only after app1 reaches terminal; wait
        // for batch 2's enqueue (the handles map still holds batch 1's
        // terminal handle until then).
        for (
          var i = 0;
          updated.where((e) => e == app2Id).length < 2 && i < 100;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        handles[app2Id]!.emit(const Done(result: OperationResult()));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('per-row done invalidates the updates provider', (
      tester,
    ) async {
      final flags = testFlags();
      final (:backend, :handles, :updated) = scriptable([
        _update('fake.app1', 'Fake App One', '1.0', '2.0'),
      ]);
      final host = StoreHost(flags: flags)..registerBackend(backend);

      var checkCalls = 0;
      await pumpSection(
        tester,
        host,
        flags,
        extraOverrides: [
          unifiedUpdatesProvider.overrideWith((ref) async {
            checkCalls++;
            return backend.checkUpdates();
          }),
        ],
      );
      await tester.pumpAndSettle();
      expect(checkCalls, 1);

      // Fail via update-all (batch-end invalidate), then retry the row
      // to Done (row-level invalidate).
      await tester.tap(find.text(tester.l10n.managePageUpdateAllLabel));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(
        const Failed(error: NetworkException(debugDetail: 'boom')),
      );
      await waitForText(tester, tester.l10n.operationFailureNetwork);
      expect(checkCalls, 2);

      await tester.tap(find.widgetWithText(TextButton, retryLabel(tester)));
      await waitForRowInflight(tester, handles, app1Id);
      handles[app1Id]!.emit(const Done(result: OperationResult()));
      await tester.pumpAndSettle();
      expect(checkCalls, 3);
      expect(find.byIcon(YaruIcons.ok), findsOneWidget);
    });
  });

  group('flag on: ManagePage composition', () {
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

    List<Override> legacyOverrides() => [
      localDebsProvider.overrideWith((ref) async => []),
      localDebUpdatesModelProvider.overrideWith(
        LocalDebUpdatesModel.new,
      ),
      launchProvider.overrideWith((_, __) => createMockSnapLauncher()),
      // The mock snaps are system snaps, hidden by default.
      showLocalSystemAppsProvider.overrideWith((ref) => true),
    ];

    testWidgets('updates.unified only: unified section over legacy list', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend(
            updates: [_update('fake.app1', 'Fake App One', '1.0', '2.0')],
          ),
        );

      await tester.pumpApp(
        (_) => ProviderScope(
          overrides: [
            ...legacyOverrides(),
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
          child: const ManagePage(),
        ),
      );
      await tester.pumpAndSettle();

      // Unified updates section replaces the legacy updates sections...
      expect(find.byType(UnifiedUpdatesSection), findsOneWidget);
      expect(find.text('Fake App One'), findsOneWidget);
      // ...so the legacy check-for-updates action row is gone...
      expect(
        find.text(tester.l10n.managePageCheckForUpdates),
        findsNothing,
      );
      // ...while the legacy installed list below is untouched.
      expect(find.text('Test Snap'), findsOneWidget);
    });

    testWidgets('both flags on: unified section over unified list', (
      tester,
    ) async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'pages.manage.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend(
            updates: [_update('fake.app1', 'Fake App One', '1.0', '2.0')],
            installed: [
              _installedApp('fake.app1', 'Fake App One', '1.0'),
            ],
          ),
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

      expect(find.byType(UnifiedUpdatesManagePage), findsOneWidget);
      expect(find.byType(UnifiedUpdatesSection), findsOneWidget);
      // Updates row...
      expect(find.text('1.0 → 2.0'), findsOneWidget);
      // ...above the unified installed list.
      expect(find.text('Fake App One'), findsNWidgets(2));
      expect(find.text('fake'), findsNWidgets(2));
    });
  });

  group('flag off (default): legacy updates sections unchanged', () {
    setUp(() {
      registerMockSnapdService(
        installedSnaps: [
          createSnap(name: 'testsnap', title: 'Test Snap', version: '1.0'),
        ],
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

    testWidgets('renders the legacy updates surface', (tester) async {
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
      expect(find.byType(UnifiedUpdatesSection), findsNothing);
      expect(find.byType(UnifiedUpdatesManagePage), findsNothing);
    });
  });
}

UpdateInfo _update(
  String nativeId,
  String name,
  String? fromVersion,
  String? toVersion,
) => UpdateInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
  fromVersion: fromVersion,
  toVersion: toVersion,
);

AppInfo _installedApp(String nativeId, String name, String version) => AppInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
  summary: 'A stub installed app.',
  iconUrl: '',
  source: AppSource.snap,
  version: version,
  installedVersion: version,
);

/// Minimal backend stub for the updates slice: canned [checkUpdates]
/// results, an [update] that records identities and completes
/// immediately, and a canned installed list for the combined page.
class _StubUpdatesBackend extends StoreBackend {
  _StubUpdatesBackend({
    required this.updates,
    this.installed = const [],
    this.updateOverride,
  });

  final List<UpdateInfo> updates;
  final List<AppInfo> installed;

  /// Optional hook for per-row terminal-outcome tests: return a
  /// scriptable handle (or throw) instead of the instant-Done default.
  final Future<OperationHandle> Function(AppIdentity id)? updateOverride;

  int checkUpdatesCalls = 0;
  final List<AppIdentity> updatedIdentities = [];

  @override
  String get id => 'fake';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {
    BackendCapability.details,
    BackendCapability.remove,
    BackendCapability.update,
  };

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => const Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) async =>
      AppDetails(app: _appFor(id), description: 'Stub details.');

  AppInfo _appFor(AppIdentity id) =>
      installed.where((a) => a.identity == id).firstOrNull ??
      _installedApp(id.nativeId, id.nativeId, '1.0');

  @override
  Future<OperationHandle> install(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> remove(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> update(AppIdentity id) async {
    final override = updateOverride;
    if (override != null) return override(id);
    updatedIdentities.add(id);
    return _FakeUpdateHandle(id);
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    checkUpdatesCalls++;
    return updates;
  }

  @override
  Future<List<AppInfo>> listInstalled() async => installed;

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}

/// An already-terminal update handle: the section's update-all waits on
/// it without hanging.
class _FakeUpdateHandle implements OperationHandle {
  _FakeUpdateHandle(this._app);

  final AppIdentity _app;

  static const _done = Done(result: OperationResult());

  @override
  String get id => 'fake-update-handle';

  @override
  AppIdentity get app => _app;

  @override
  OperationKind get kind => OperationKind.update;

  @override
  Stream<OperationState> get state => Stream.value(_done);

  @override
  OperationState get current => _done;

  @override
  Future<void> cancel() async {}
}
