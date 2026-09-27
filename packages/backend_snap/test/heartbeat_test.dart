/// Heartbeat wiring test (stall-watchdog.md §1): a change stuck in
/// `download-snap` emits nothing for a long stretch. The poll loop must
/// re-emit the silent [Downloading] phase (a legal self-transition per
/// the DAG), and the re-emit must stop once the operation terminates.
/// Scripted transport — never touches the live system.
library;

import 'dart:async';

import 'package:backend_snap/backend_snap.dart';
import 'package:test/test.dart';

/// Returns the same `download-snap` snapshot [pollsLeft] times, then a
/// Done snapshot. Identical payloads, so [_emitState]'s progress-dedupe
/// emits only once — only the heartbeat can re-emit.
class _StuckDownloadTransport extends SnapdTransport {
  _StuckDownloadTransport(this.pollsLeft);

  int pollsLeft;

  @override
  Future<void> checkAvailable() async {}

  @override
  Future<List<SnapSummaryData>> find(String query) async => const [];

  @override
  Future<SnapSummaryData> getDetails(String name) =>
      throw SnapdNotFoundException('no $name');

  @override
  Future<List<String>> installedNames() async => const [];

  @override
  Future<List<SnapSummaryData>> installedSnaps() async => const [];

  @override
  Future<List<SnapSummaryData>> updatesAvailable() async => const [];

  @override
  Future<String> install(String name, {required bool classic}) async =>
      'change-stuck';

  @override
  Future<String> remove(String name) async => throw UnimplementedError();

  @override
  Future<String> refresh(String name) async => throw UnimplementedError();

  @override
  Future<SnapdChangeSnapshot> getChange(String id) async {
    if (pollsLeft-- > 0) {
      return const SnapdChangeSnapshot(
        id: 'change-stuck',
        kind: 'install',
        status: 'Doing',
        ready: false,
        error: '',
        snapNames: ['test-snap'],
        tasks: [
          SnapdTaskSnapshot(
            kind: 'download-snap',
            status: 'Doing',
            done: 30,
            total: 100,
          ),
        ],
      );
    }
    return const SnapdChangeSnapshot(
      id: 'change-stuck',
      kind: 'install',
      status: 'Done',
      ready: true,
      error: '',
      snapNames: ['test-snap'],
      tasks: [],
    );
  }

  @override
  Future<List<SnapdChangeSnapshot>> inProgressChanges() async => const [];

  @override
  Future<void> abortChange(String id) async {}
}

void main() {
  group('snap heartbeat', () {
    test('re-emits a silent downloading phase; stops at terminal', () async {
      final handle = SnapOperationHandle(
        app: const AppIdentity(backendId: 'snap', nativeId: 'test-snap'),
        kind: OperationKind.install,
        transport: _StuckDownloadTransport(30),
        changeId: 'change-stuck',
        mapError: (e) =>
            UnknownStoreException(debugDetail: e.message, backendId: 'snap'),
        pollInterval: const Duration(milliseconds: 10),
        heartbeatInterval: const Duration(milliseconds: 60),
      );
      final states = <OperationState>[];
      final sub = handle.state.listen(states.add);
      // Attach before any terminal can be emitted — broadcast streams
      // do not replay.
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

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
        expect(d.bytesDone, 30);
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
