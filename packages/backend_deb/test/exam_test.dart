import 'package:backend_deb/backend_deb.dart';
import 'package:backend_deb/testing.dart';
import 'package:store_contracts/exam.dart';
import 'package:test/test.dart';

void main() {
  group('deb backend', () {
    test('passes the full contract exam', () async {
      await runContractExam(
        'deb',
        () => BackendDeb(transport: StubPackageKitTransport()),
        installTarget: const AppIdentity(
          backendId: 'deb',
          nativeId: 'test-deb',
        ),
        unknownTarget: const AppIdentity(
          backendId: 'deb',
          nativeId: 'no.such.deb',
        ),
        installedTarget: const AppIdentity(
          backendId: 'deb',
          nativeId: 'installed-deb',
        ),
      );
    });
  });

  group('BackendDeb behaviour', () {
    test('search maps packagekit results to AppInfo', () async {
      final backend = BackendDeb(transport: StubPackageKitTransport());
      final results = await backend.search('test').toList();
      expect(results, hasLength(1));
      expect(results.first.identity.nativeId, 'test-deb');
      expect(results.first.source, AppSource.deb);
    });

    test(
      'getDetails surfaces the unsandboxed permission pre-install',
      () async {
        final backend = BackendDeb(transport: StubPackageKitTransport());
        final details = await backend.getDetails(
          const AppIdentity(backendId: 'deb', nativeId: 'test-deb'),
        );
        expect(details.permissions, hasLength(1));
        expect(details.permissions.first.id, 'confinement-none');
        expect(details.permissions.first.label, contains('Unsandboxed'));
      },
    );

    test('getDetails of unknown package throws AppNotFoundException', () async {
      final backend = BackendDeb(transport: StubPackageKitTransport());
      expect(
        () => backend.getDetails(
          const AppIdentity(backendId: 'deb', nativeId: 'no.such.deb'),
        ),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('checkUpdates maps updatable packages', () async {
      final backend = BackendDeb(transport: StubPackageKitTransport());
      final updates = await backend.checkUpdates();
      expect(updates, hasLength(1));
      expect(updates.first.identity.nativeId, 'installed-deb');
      expect(updates.first.toVersion, '2.1');
      expect(updates.first.fromVersion, '2.0');
    });

    test('remove reaches a terminal state', () async {
      final backend = BackendDeb(transport: StubPackageKitTransport());
      final handle = await backend.remove(
        const AppIdentity(backendId: 'deb', nativeId: 'installed-deb'),
      );
      final terminal = await handle.state
          .firstWhere((s) => s.isTerminal)
          .timeout(const Duration(seconds: 30));
      expect(terminal, isA<Done>());
    });

    test('update reaches a terminal state', () async {
      final backend = BackendDeb(transport: StubPackageKitTransport());
      final handle = await backend.update(
        const AppIdentity(backendId: 'deb', nativeId: 'installed-deb'),
      );
      final terminal = await handle.state
          .firstWhere((s) => s.isTerminal)
          .timeout(const Duration(seconds: 30));
      expect(terminal, isA<Done>());
    });

    test('recoverInFlight is honestly empty in v1', () async {
      final backend = BackendDeb(transport: StubPackageKitTransport());
      expect(await backend.recoverInFlight(), isEmpty);
    });
  });

  group('BackendDeb.listInstalled', () {
    test(
      'maps installed names to AppInfos with installedVersion set',
      () async {
        final backend = BackendDeb(transport: StubPackageKitTransport());
        final apps = await backend.listInstalled();
        expect(apps, hasLength(1));
        final app = apps.first;
        expect(app.identity.backendId, 'deb');
        expect(app.identity.nativeId, 'installed-deb');
        expect(app.name, 'installed-deb');
        expect(app.source, AppSource.deb);
        expect(app.installedVersion, '2.0');
        expect(app.isInstalled, isTrue);
      },
    );

    test('skips entries whose details vanished mid-enumeration', () async {
      final backend = BackendDeb(transport: _GhostDebTransport());
      final apps = await backend.listInstalled();
      expect(apps.map((a) => a.identity.nativeId), ['installed-deb']);
    });

    test('transport failure throws a typed StoreException', () async {
      final backend = BackendDeb(transport: _DeadDebTransport());
      expect(
        () => backend.listInstalled(),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('empty installed list returns []', () async {
      final backend = BackendDeb(transport: _EmptyDebTransport());
      expect(await backend.listInstalled(), isEmpty);
    });
  });
}

/// Reports a ghost package alongside the real one; its details 404.
/// The bulk path is unavailable so the legacy enumeration (and its
/// mid-enumeration skip) is exercised.
class _GhostDebTransport extends StubPackageKitTransport {
  @override
  Future<List<DebPackageData>> installedPackages() =>
      throw PackageKitTransportException('bulk unavailable');

  @override
  Future<List<String>> installedNames() async => const [
    'installed-deb',
    'ghost-deb',
  ];

  @override
  Future<DebPackageData> getDetails(String name) async {
    if (name == 'ghost-deb') {
      throw PackageKitNotFoundException('package "ghost-deb" not found');
    }
    return super.getDetails(name);
  }
}

/// PackageKit daemon unreachable.
class _DeadDebTransport extends StubPackageKitTransport {
  @override
  Future<List<DebPackageData>> installedPackages() =>
      throw PackageKitTransportException('dbus service unknown');

  @override
  Future<List<String>> installedNames() async =>
      throw PackageKitTransportException('dbus service unknown');
}

/// Nothing installed.
class _EmptyDebTransport extends StubPackageKitTransport {
  @override
  Future<List<String>> installedNames() async => const [];

  @override
  Future<List<DebPackageData>> installedPackages() async => const [];
}
