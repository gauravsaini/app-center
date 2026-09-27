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

  group('BackendSnap identity signals (phase3-slice2)', () {
    test('search harvests website + first non-empty commonId', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final results = await backend.search('test').toList();
      expect(results, hasLength(1));
      final signal = results.first.identitySignal!;
      expect(signal.homepageUrl, 'https://example.com/test-snap');
      // The fixture's first commonId is '' — the first NON-EMPTY wins.
      expect(signal.appstreamId, 'io.example.TestSnap');
    });

    test('getDetails populates AppDetails.homepage from website', () async {
      final backend = BackendSnap(transport: StubSnapdTransport());
      final details = await backend.getDetails(
        const AppIdentity(backendId: 'snap', nativeId: 'test-snap'),
      );
      expect(details.homepage, 'https://example.com/test-snap');
      expect(details.app.identitySignal!.appstreamId, 'io.example.TestSnap');
    });

    test(
      'listInstalled carries signals through the installed mapping',
      () async {
        final backend = BackendSnap(transport: StubSnapdTransport());
        final apps = await backend.listInstalled();
        expect(apps, hasLength(1));
        final signal = apps.first.identitySignal!;
        expect(signal.homepageUrl, 'https://example.com/installed-snap');
        expect(signal.appstreamId, 'io.example.InstalledSnap');
      },
    );

    test(
      'snap without wire signals reports null, never empty strings',
      () async {
        final backend = BackendSnap(transport: _NoSignalSnapTransport());
        final results = await backend.search('test').toList();
        expect(results, hasLength(1));
        expect(results.first.identitySignal, isNull);
      },
    );
  });

  group('BackendSnap.listInstalled', () {
    test(
      'maps installed names to AppInfos with installedVersion set',
      () async {
        final backend = BackendSnap(transport: StubSnapdTransport());
        final apps = await backend.listInstalled();
        expect(apps, hasLength(1));
        final app = apps.first;
        expect(app.identity.backendId, 'snap');
        expect(app.identity.nativeId, 'installed-snap');
        expect(app.name, 'Installed Snap');
        expect(app.source, AppSource.snap);
        expect(app.installedVersion, '2.0');
        expect(app.isInstalled, isTrue);
      },
    );

    test('skips entries whose details vanished mid-enumeration', () async {
      final backend = BackendSnap(transport: _GhostSnapTransport());
      final apps = await backend.listInstalled();
      expect(apps.map((a) => a.identity.nativeId), ['installed-snap']);
    });

    test('transport failure throws a typed StoreException', () async {
      final backend = BackendSnap(transport: _DeadSnapdTransport());
      expect(
        () => backend.listInstalled(),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('empty installed list returns []', () async {
      final backend = BackendSnap(transport: _EmptySnapdTransport());
      expect(await backend.listInstalled(), isEmpty);
    });
  });
}

/// Reports a ghost snap alongside the real one; its details 404.
class _GhostSnapTransport extends StubSnapdTransport {
  @override
  Future<List<String>> installedNames() async => const [
    'installed-snap',
    'ghost-snap',
  ];

  @override
  Future<SnapSummaryData> getDetails(String name) async {
    if (name == 'ghost-snap') {
      throw SnapdNotFoundException('snap "ghost-snap" not found');
    }
    return super.getDetails(name);
  }
}

/// snapd unreachable.
class _DeadSnapdTransport extends StubSnapdTransport {
  @override
  Future<List<String>> installedNames() async =>
      throw SnapdTransportException('connection refused');
}

/// Nothing installed.
class _EmptySnapdTransport extends StubSnapdTransport {
  @override
  Future<List<String>> installedNames() async => const [];
}

/// A snap with no website/commonIds on the wire: the backend must
/// report a null signal, never empty-string fields.
class _NoSignalSnapTransport extends StubSnapdTransport {
  @override
  Future<List<SnapSummaryData>> find(String query) async => const [
    SnapSummaryData(
      name: 'plain-snap',
      title: 'Plain Snap',
      summary: 'no wire signals',
      description: '',
      version: '1.0',
      iconUrl: '',
      confinement: 'strict',
    ),
  ];
}
