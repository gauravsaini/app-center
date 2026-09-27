/// Heartbeat wiring test (stall-watchdog.md §1): a PackageKit
/// transaction that goes quiet during downloading must still see the
/// handle re-emit the silent [Downloading] phase (a legal
/// self-transition per the DAG), and the re-emit must stop once the
/// operation terminates. Scripted transaction — never touches D-Bus.
library;

import 'dart:async';

import 'package:backend_deb/backend_deb.dart';
import 'package:test/test.dart';

void main() {
  group('deb heartbeat', () {
    test('re-emits a silent downloading phase; stops at terminal', () async {
      final controller = StreamController<DebTxEvent>();
      final tx = DebTransaction(
        events: controller.stream,
        cancel: () async => controller.close(),
      );
      final handle = DebOperationHandle(
        app: const AppIdentity(backendId: 'deb', nativeId: 'test-deb'),
        kind: OperationKind.install,
        transaction: tx,
        mapError: (e) =>
            UnknownStoreException(debugDetail: e.message, backendId: 'deb'),
        heartbeatInterval: const Duration(milliseconds: 60),
      );
      final states = <OperationState>[];
      final sub = handle.state.listen(states.add);
      // Attach before any terminal can be emitted — broadcast streams
      // do not replay.
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

      controller.add(
        const DebTxProgress(status: DebTxStatus.download, percentage: 42),
      );
      // Silent phase: no transport events for well over the interval.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      controller.add(const DebTxDone(outcome: DebTxOutcome.success));
      await controller.close();

      final terminal = await terminalFuture.timeout(
        const Duration(seconds: 10),
      );
      // Quiet window: the heartbeat must not emit after the terminal.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(terminal, isA<Done>());
      final downloads = states.whereType<Downloading>().toList();
      expect(
        downloads.length,
        greaterThan(1),
        reason: 'the silent downloading phase must be re-emitted',
      );
      for (final d in downloads) {
        expect(d.bytesDone, 42);
        expect(d.bytesTotal, 100);
      }
      expect(
        states.indexOf(terminal),
        states.length - 1,
        reason: 'no emission after the terminal state',
      );
    });
  });
}
