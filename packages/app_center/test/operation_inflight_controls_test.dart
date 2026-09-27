/// Widget tests for [OperationInFlightControls].
///
/// Uses [FakeInFlightHandle] to script states: determinate vs indeterminate
/// rendering, the "Cancelling…" caption, cancel dispatch, and live
/// transitions on the state stream.
library;

import 'package:app_center/widgets/operation_inflight_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'fake_inflight_handle.dart';
import 'test_utils.dart';

void main() {
  tearDown(resetAllServices);

  const identity = AppIdentity(backendId: 'deb', nativeId: 'test-deb');

  late FakeInFlightHandle handle;
  final handles = <FakeInFlightHandle>[];

  setUp(() {
    handle = FakeInFlightHandle(app: identity);
    handles.add(handle);
  });

  tearDown(() async {
    for (final h in handles) {
      await h.dispose();
    }
    handles.clear();
  });

  Future<void> pumpControls(WidgetTester tester, FakeInFlightHandle h) {
    return tester.pumpApp((_) => OperationInFlightControls(handle: h));
  }

  LinearProgressIndicator barOf(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );

  /// The fake's state stream is an async broadcast controller (like the
  /// real handles'), so give each emitted event a chance to land before
  /// asserting.
  Future<void> emitAndPump(
    WidgetTester tester,
    OperationState state,
  ) async {
    handle.emit(state);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('determinate download renders fraction', (tester) async {
    handle.emit(const Downloading(bytesDone: 3, bytesTotal: 10));
    await pumpControls(tester, handle);
    await tester.pump();

    expect(barOf(tester).value, 0.3);
  });

  testWidgets('applying renders indeterminate', (tester) async {
    handle.emit(const Applying());
    await pumpControls(tester, handle);
    await tester.pump();

    expect(barOf(tester).value, isNull);
  });

  testWidgets('download with unknown size renders indeterminate', (
    tester,
  ) async {
    handle.emit(const Downloading(bytesDone: 3));
    await pumpControls(tester, handle);
    await tester.pump();

    expect(barOf(tester).value, isNull);
  });

  testWidgets('cancelling shows the cancelling caption', (tester) async {
    handle.emit(const Cancelling());
    await pumpControls(tester, handle);
    await tester.pump();

    expect(find.text(tester.l10n.snapActionCancellingLabel), findsOneWidget);
    expect(barOf(tester).value, isNull);
  });

  testWidgets('tapping stop calls handle.cancel exactly once', (
    tester,
  ) async {
    handle.emit(const Applying());
    await pumpControls(tester, handle);
    await tester.pump();

    await tester.tap(find.widgetWithIcon(IconButton, YaruIcons.stop));
    await tester.pump();

    expect(handle.cancelCallCount, 1);
    // cancel() also emits Cancelling: the caption lands on the next frame.
    expect(find.text(tester.l10n.snapActionCancellingLabel), findsOneWidget);
  });

  testWidgets('live transitions update the bar', (tester) async {
    handle.emit(const Downloading(bytesDone: 3, bytesTotal: 10));
    await pumpControls(tester, handle);
    await tester.pump();

    expect(barOf(tester).value, 0.3);

    await emitAndPump(tester, const Applying());

    expect(barOf(tester).value, isNull);

    await emitAndPump(tester, const Downloading(bytesDone: 9, bytesTotal: 10));

    expect(barOf(tester).value, closeTo(0.9, 0.001));
  });
}
