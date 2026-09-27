/// Widget tests for the stalled caption in [OperationInFlightControls].
///
/// Uses [FakeStallAwareHandle]: [FakeInFlightHandle] plus a scriptable
/// [StallAware] flag, mirroring the engine watchdog firing on a handle
/// whose backend never acknowledges the cancel (no `Cancelling` event).
library;

import 'dart:async';

import 'package:app_center/widgets/operation_inflight_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'fake_inflight_handle.dart';
import 'test_utils.dart';

/// Scriptable [OperationHandle] + [StallAware].
///
/// The watchdog fires once (false → true only, per the contract); tests
/// script it via [fireWatchdog].
class FakeStallAwareHandle extends FakeInFlightHandle implements StallAware {
  FakeStallAwareHandle({required super.app, super.initial});

  bool _stalled = false;
  final _stalledController = StreamController<bool>.broadcast();

  @override
  bool get isStalled => _stalled;

  @override
  Stream<bool> get stalledChanges => _stalledController.stream;

  /// Script the watchdog firing: set the flag and push to the stream.
  void fireWatchdog() {
    _stalled = true;
    _stalledController.add(true);
  }

  @override
  Future<void> dispose() async {
    await _stalledController.close();
    await super.dispose();
  }
}

void main() {
  tearDown(resetAllServices);

  const identity = AppIdentity(backendId: 'deb', nativeId: 'test-deb');

  late FakeStallAwareHandle handle;
  final handles = <FakeStallAwareHandle>[];

  setUp(() {
    handle = FakeStallAwareHandle(app: identity);
    handles.add(handle);
  });

  tearDown(() async {
    for (final h in handles) {
      await h.dispose();
    }
    handles.clear();
  });

  Future<void> pumpControls(WidgetTester tester, FakeStallAwareHandle h) {
    return tester.pumpApp((_) => OperationInFlightControls(handle: h));
  }

  /// The fake's streams are broadcast (like the real handles'), so give
  /// each emitted event a chance to land before asserting.
  Future<void> pumpTwice(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('stalled handle in a non-cancelling state shows the caption', (
    tester,
  ) async {
    handle.fireWatchdog();
    handle.emit(const Applying());
    await pumpControls(tester, handle);
    await pumpTwice(tester);

    expect(find.text(tester.l10n.stalledLabel), findsOneWidget);
  });

  testWidgets('stalled handle in Cancelling shows the cancelling caption', (
    tester,
  ) async {
    handle.fireWatchdog();
    handle.emit(const Cancelling());
    await pumpControls(tester, handle);
    await pumpTwice(tester);

    expect(find.text(tester.l10n.snapActionCancellingLabel), findsOneWidget);
    expect(find.text(tester.l10n.stalledLabel), findsNothing);
  });

  testWidgets('non-stalled handle renders no stalled caption', (tester) async {
    handle.emit(const Applying());
    await pumpControls(tester, handle);
    await pumpTwice(tester);

    expect(find.text(tester.l10n.stalledLabel), findsNothing);
  });

  testWidgets('live stalledChanges update the caption', (tester) async {
    handle.emit(const Applying());
    await pumpControls(tester, handle);
    await pumpTwice(tester);

    expect(find.text(tester.l10n.stalledLabel), findsNothing);

    handle.fireWatchdog();
    await pumpTwice(tester);

    expect(find.text(tester.l10n.stalledLabel), findsOneWidget);
  });
}
