/// Heartbeat wiring test (stall-watchdog.md §1): a flatpak process
/// that stops printing progress lines must still see the handle re-emit
/// the silent [Downloading] phase (a legal self-transition per the DAG),
/// and the re-emit must stop once the operation terminates.
/// Scripted process — never touches the live system.
library;

import 'dart:async';

import 'package:backend_flatpak/backend_flatpak.dart';
import 'package:test/test.dart';

/// A process that emits progress only when told to and exits only when
/// told to, so the test can hold it in a silent downloading phase.
class _HangingProcess implements FlatpakProcess {
  final _stdout = StreamController<String>.broadcast();
  final _exit = Completer<int>();

  void progress(String line) => _stdout.add(line);
  void finish(int code) => _exit.complete(code);

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> terminate({Duration grace = const Duration(seconds: 2)}) async {}
}

void main() {
  group('flatpak heartbeat', () {
    test('re-emits a silent downloading phase; stops at terminal', () async {
      final proc = _HangingProcess();
      final handle = FlatpakOperationHandle(
        app: const AppIdentity(backendId: 'flatpak', nativeId: 'org.test.App'),
        kind: OperationKind.install,
        process: proc,
        mapError: (e) =>
            UnknownStoreException(debugDetail: '$e', backendId: 'flatpak'),
        heartbeatInterval: const Duration(milliseconds: 60),
      );
      final states = <OperationState>[];
      final sub = handle.state.listen(states.add);
      // Attach before any terminal can be emitted — broadcast streams
      // do not replay.
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

      // Wait for the handle to subscribe to the process output first —
      // broadcast lines emitted earlier would be lost.
      await handle.state
          .firstWhere((s) => s is Preparing)
          .timeout(const Duration(seconds: 10));
      proc.progress('Downloading: 10%');
      // Silent phase: no progress lines for well over the interval.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      proc.finish(0);

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
      final first = downloads.first;
      for (final d in downloads) {
        expect(d.bytesDone, first.bytesDone);
        expect(d.bytesTotal, first.bytesTotal);
      }
      expect(
        states.indexOf(terminal),
        states.length - 1,
        reason: 'no emission after the terminal state',
      );
    });
  });
}
