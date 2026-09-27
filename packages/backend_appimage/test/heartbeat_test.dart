/// Heartbeat wiring test (stall-watchdog.md §1): a body stuck in
/// [Applying] (the long silent copy+hash) must still see the handle
/// re-emit the silent phase (a legal self-transition per the DAG), and
/// the re-emit must stop once the operation terminates.
library;

import 'dart:async';

import 'package:backend_appimage/src/handle.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('appimage heartbeat', () {
    test('re-emits a silent applying phase; stops at terminal', () async {
      final gate = Completer<OperationResult>();
      final handle = AppimageOperationHandle.run(
        app: const AppIdentity(backendId: 'appimage', nativeId: 'test-app'),
        kind: OperationKind.install,
        heartbeatInterval: const Duration(milliseconds: 60),
        body: (h) async {
          h.emit(const Applying());
          return gate.future;
        },
      );
      final states = <OperationState>[];
      final sub = handle.state.listen(states.add);
      // Attach before any terminal can be emitted — broadcast streams
      // do not replay.
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

      // Silent phase: the body emits nothing for well over the interval.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      gate.complete(const OperationResult());

      final terminal = await terminalFuture.timeout(
        const Duration(seconds: 10),
      );
      // Quiet window: the heartbeat must not emit after the terminal.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(terminal, isA<Done>());
      final applying = states.whereType<Applying>().toList();
      expect(
        applying.length,
        greaterThan(1),
        reason: 'the silent applying phase must be re-emitted',
      );
      expect(
        states.indexOf(terminal),
        states.length - 1,
        reason: 'no emission after the terminal state',
      );
    });
  });
}
