import 'package:backend_snap/backend_snap.dart';
import 'package:backend_snap/testing.dart';
import 'package:store_contracts/exam.dart';
import 'package:test/test.dart';

void main() {
  group('snap backend', () {
    test('passes the full contract exam', () async {
      await runContractExam(
        'snap',
        () => BackendSnap(transport: StubSnapdTransport()),
        installTarget: const AppIdentity(
          backendId: 'snap',
          nativeId: 'test-snap',
        ),
        unknownTarget: const AppIdentity(
          backendId: 'snap',
          nativeId: 'no.such.snap',
        ),
        installedTarget: const AppIdentity(
          backendId: 'snap',
          nativeId: 'installed-snap',
        ),
      );
    });
  });

  group('BackendSnap behaviour', () {
    test('search maps snapd find results to AppInfo', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final results = await backend.search('test').toList();
      expect(results, hasLength(1));
      expect(results.first.identity.nativeId, 'test-snap');
      expect(results.first.source, AppSource.snap);
    });

    test('getDetails surfaces confinement as pre-install permission', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final details = await backend.getDetails(
        const AppIdentity(backendId: 'snap', nativeId: 'installed-snap'),
      );
      expect(details.permissions, hasLength(1));
      expect(details.permissions.first.id, 'confinement-classic');
      expect(details.permissions.first.label, contains('Classic'));
    });

    test('getDetails of unknown snap throws AppNotFoundException', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      expect(
        () => backend.getDetails(
          const AppIdentity(backendId: 'snap', nativeId: 'no.such.snap'),
        ),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('checkUpdates maps refreshable snaps', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final updates = await backend.checkUpdates();
      expect(updates, hasLength(1));
      expect(updates.first.identity.nativeId, 'installed-snap');
      expect(updates.first.toVersion, '2.1');
      expect(updates.first.fromVersion, '2.0');
    });

    test('remove reaches a terminal state', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final handle = await backend.remove(
        const AppIdentity(backendId: 'snap', nativeId: 'installed-snap'),
      );
      final terminal = await handle.state
          .firstWhere((s) => s.isTerminal)
          .timeout(const Duration(seconds: 30));
      expect(terminal, isA<Done>());
    });

    test('update reaches a terminal state', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final handle = await backend.update(
        const AppIdentity(backendId: 'snap', nativeId: 'installed-snap'),
      );
      final terminal = await handle.state
          .firstWhere((s) => s.isTerminal)
          .timeout(const Duration(seconds: 30));
      expect(terminal, isA<Done>());
    });
  });
}
