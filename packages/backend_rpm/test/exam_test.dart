import 'dart:async';

import 'package:backend_rpm/backend_rpm.dart';
import 'package:backend_rpm/src/handle.dart';
import 'package:backend_rpm/src/packagekit_transport.dart';
import 'package:backend_rpm/src/transport.dart';
import 'package:backend_rpm/testing.dart';
import 'package:store_contracts/exam.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

const _installId = StubRpmTransport.installTargetId;
const _installedId = StubRpmTransport.installedTargetId;
const _glibcId = StubRpmTransport.glibcI686Id;
const _unknownId = StubRpmTransport.unknownTargetId;

AppIdentity _id(String nativeId) =>
    AppIdentity(backendId: 'rpm', nativeId: nativeId);

BackendRpm _create() => BackendRpm(transport: StubRpmTransport());

Future<OperationState> _driveToTerminal(OperationHandle handle) async {
  final sub = handle.state.listen((_) {});
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!handle.current.isTerminal) {
      if (DateTime.now().isAfter(deadline)) {
        fail('no terminal state; stuck at ${handle.current.runtimeType}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return handle.current;
  } finally {
    await sub.cancel();
  }
}

/// A stub whose search always fails with [failure], for error-mapping
/// tests.
class _FailingSearchTransport extends StubRpmTransport {
  _FailingSearchTransport(this.failure);

  final RpmTransportException failure;

  @override
  Future<List<RpmPackageData>> search(String query) async => throw failure;
}

void main() {
  group('rpm backend', () {
    test('passes the full contract exam', () async {
      await runContractExam(
        'rpm',
        _create,
        installTarget: _id(_installId),
        unknownTarget: _id(_unknownId),
        installedTarget: _id(_installedId),
      );
    });

    test('id is rpm and contractVersion matches store_contracts', () {
      final backend = _create();
      expect(backend.id, 'rpm');
      expect(backend.contractVersion, storeContractsMajor);
    });

    test('capabilities are exactly the LLD set', () {
      final backend = _create();
      expect(backend.capabilities, {
        BackendCapability.search,
        BackendCapability.details,
        BackendCapability.install,
        BackendCapability.remove,
        BackendCapability.update,
        BackendCapability.permissions,
      });
    });

    test(
      'checkUpdates maps from/to versions; recoverInFlight is empty',
      () async {
        final backend = _create();
        final updates = await backend.checkUpdates();
        expect(updates, hasLength(1));
        final u = updates.single;
        expect(u.identity.backendId, 'rpm');
        expect(u.name, 'firefox');
        expect(u.fromVersion, '135.0-1.fc42');
        expect(u.toVersion, '136.0-1.fc42');
        expect(await backend.recoverInFlight(), isEmpty);
      },
    );

    test('listInstalled keeps multi-arch entries as separate cards', () async {
      final backend = _create();
      final apps = await backend.listInstalled();
      expect(apps, hasLength(2));
      for (final app in apps) {
        expect(app.identity.backendId, 'rpm');
        // Labeling honesty (HLD §5): rpm results are never labeled deb.
        expect(app.source, AppSource.rpm);
        expect(app.isInstalled, isTrue);
      }
      final byCard = {for (final a in apps) a.identity.nativeId: a};
      expect(byCard[_installedId]!.name, 'firefox');
      expect(byCard[_installedId]!.installedVersion, '135.0-1.fc42');
      expect(byCard[_glibcId]!.name, 'glibc');
      expect(byCard[_glibcId]!.installedVersion, '2.39-2.fc42');
    });

    test('search returns one card per (name, arch)', () async {
      final backend = _create();
      final results = await backend.search('firefox').toList();
      expect(results, hasLength(2));
      final cards = results
          .map((r) => '${r.name}.${r.identity.nativeId.split(';')[2]}')
          .toSet();
      expect(cards, {'firefox.x86_64', 'firefox.i686'});
      for (final r in results) {
        expect(r.source, AppSource.rpm);
      }
      expect(await backend.search('zzz-no-such-app').toList(), isEmpty);
    });

    test(
      'install on installed (name, arch) is a noop, no transaction',
      () async {
        final transport = StubRpmTransport();
        final backend = BackendRpm(transport: transport);
        final terminal = await _driveToTerminal(
          await backend.install(_id(_installedId)),
        );
        expect(terminal, isA<Done>());
        expect((terminal as Done).result.noop, isTrue);
        expect(transport.installCalls, isEmpty);
      },
    );

    test('getDetails of unknown id throws AppNotFoundException', () async {
      final backend = _create();
      expect(
        () => backend.getDetails(_id(_unknownId)),
        throwsA(isA<AppNotFoundException>()),
      );
    });
  });

  group('package-id parser', () {
    test('accepts 5 tokens and splits the fields', () {
      final id = RpmPackageId.parse(
        'firefox;135.0-1.fc42;x86_64;updates;installed',
      );
      expect(id.name, 'firefox');
      expect(id.evr, '135.0-1.fc42');
      expect(id.arch, 'x86_64');
      expect(id.origin, 'updates');
      expect(id.data, 'installed');
      expect(id.isInstalled, isTrue);
    });

    test('rejects 4-token ids (the apt shape)', () {
      expect(
        () => RpmPackageId.parse('firefox;135.0-1;x86_64;installed'),
        throwsFormatException,
      );
    });

    test('rejects 6-token ids', () {
      expect(() => RpmPackageId.parse('a;b;c;d;e;f'), throwsFormatException);
    });

    test('rejects empty names, empty strings, and garbage', () {
      expect(() => RpmPackageId.parse(''), throwsFormatException);
      expect(
        () => RpmPackageId.parse(';1.0;x86_64;fedora;'),
        throwsFormatException,
      );
      expect(
        () => RpmPackageId.parse('firefox;1.0;;fedora;'),
        throwsFormatException,
      );
      expect(() => RpmPackageId.parse('not-an-id'), throwsFormatException);
    });

    test('EVR is carried verbatim, never split', () {
      // Epoch form: string surgery would corrupt identity (research §1.2).
      final epoch = RpmPackageId.parse('foo;1:2.0-1.fc42;x86_64;fedora;');
      expect(epoch.evr, '1:2.0-1.fc42');
      final empty = RpmPackageId.parse('foo;;x86_64;fedora;');
      expect(empty.evr, isEmpty);
    });

    test('cardKey, isInstalled, and verbatim round-trip', () {
      const raw = 'firefox;135.0-1.fc42;x86_64;updates;installed';
      final id = RpmPackageId.parse(raw);
      expect(id.cardKey, 'firefox.x86_64');
      expect(id.toString(), raw);
      expect(parsePackageId(raw).cardKey, 'firefox.x86_64');
      expect(
        RpmPackageId.parse('vim;9.1-1.fc42;x86_64;fedora;').isInstalled,
        isFalse,
      );
      expect(
        displaySubtitle('firefox', 'x86_64', hasSiblingArch: true),
        'firefox · x86_64',
      );
      expect(
        displaySubtitle('firefox', 'x86_64', hasSiblingArch: false),
        'firefox',
      );
    });
  });

  group('bulk merge', () {
    test("prefers the installed event's EVR", () {
      final events = [
        const RpmRawPackage(
          installed: false,
          id: 'vim;9.2-1.fc42;x86_64;updates;',
          summary: 'available',
        ),
        const RpmRawPackage(
          installed: true,
          id: 'vim;9.1-1.fc42;x86_64;fedora;installed',
          summary: 'installed',
        ),
      ];
      final merged = RealRpmPackageKitTransport.mergeInstalledPackages(
        events,
        const [],
      );
      expect(merged, hasLength(1));
      expect(merged.single.evr, '9.1-1.fc42');
      expect(merged.single.installed, isTrue);
    });

    test('Details summary wins; falls back to the Package-event summary', () {
      final events = [
        const RpmRawPackage(
          installed: true,
          id: 'a;1.0-1.fc42;x86_64;fedora;installed',
          summary: 'package-event summary',
        ),
        const RpmRawPackage(
          installed: true,
          id: 'b;1.0-1.fc42;x86_64;fedora;installed',
          summary: 'package-event summary',
        ),
      ];
      final details = [
        const RpmRawDetails(
          id: 'a;1.0-1.fc42;x86_64;fedora;installed',
          summary: 'details summary',
          description: 'long description',
        ),
        const RpmRawDetails(
          id: 'b;1.0-1.fc42;x86_64;fedora;installed',
          summary: '',
        ),
      ];
      final merged = RealRpmPackageKitTransport.mergeInstalledPackages(
        events,
        details,
      );
      final byName = {for (final m in merged) m.name: m};
      expect(byName['a']!.summary, 'details summary');
      expect(byName['a']!.description, 'long description');
      expect(byName['b']!.summary, 'package-event summary');
    });

    test('batch failure degrades to the legacy per-package path', () async {
      final transport = StubRpmTransport()
        ..installedPackagesFailure = RpmTransportException(
          'GetDetails batch failed',
        );
      final backend = BackendRpm(transport: transport);
      final apps = await backend.listInstalled();
      // Same result as the bulk path, via installedIds + getDetails.
      expect(apps.map((a) => a.identity.nativeId).toSet(), {
        _installedId,
        _glibcId,
      });
      // installedPackages attempt (2) + installedIds (1) + 2 getDetails (4).
      expect(transport.transactionCount, 7);
    });

    test('dedupes by (name, arch): dupes collapse, arches stay separate', () {
      final events = [
        const RpmRawPackage(
          installed: true,
          id: 'firefox;135.0-1.fc42;x86_64;updates;installed',
          summary: 'x86_64',
        ),
        const RpmRawPackage(
          installed: true,
          id: 'firefox;135.0-1.fc42;i686;updates;installed',
          summary: 'i686',
        ),
        // Duplicate card: collapses into the x86_64 entry.
        const RpmRawPackage(
          installed: false,
          id: 'firefox;136.0-1.fc42;x86_64;updates;',
          summary: 'dupe',
        ),
        // Garbage id: skipped, never fatal.
        const RpmRawPackage(installed: true, id: 'garbage', summary: 'x'),
      ];
      final merged = RealRpmPackageKitTransport.mergeInstalledPackages(
        events,
        const [],
      );
      expect(merged, hasLength(2));
      expect(merged.map((m) => '${m.name}.${m.arch}').toSet(), {
        'firefox.x86_64',
        'firefox.i686',
      });
    });
  });

  group('arch filter', () {
    test('search uses the arch filter (native + noarch)', () {
      // PackageKitFilter.arch is index 18 in packagekit 0.2.7's enum.
      expect(RealRpmPackageKitTransport.searchFilterMask, 1 << 18);
    });

    test('installed enumeration carries no arch filter', () {
      // PackageKitFilter.installed is index 2; the arch bit must be
      // absent so installed compat-arch packages still list (D3).
      expect(RealRpmPackageKitTransport.installedFilterMask, 1 << 2);
      expect(RealRpmPackageKitTransport.installedFilterMask & (1 << 18), 0);
    });
  });

  group('error mapping', () {
    test('RpmNotFoundException becomes AppNotFoundException', () async {
      final backend = _create();
      expect(
        () => backend.install(_id(_unknownId)),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('daemon unreachable becomes BackendUnavailableException', () async {
      final backend = BackendRpm(
        transport: _FailingSearchTransport(
          RpmTransportException('packagekit unreachable: connection refused'),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('disk-full becomes DiskSpaceException', () async {
      final backend = BackendRpm(
        transport: _FailingSearchTransport(
          RpmTransportException('noSpaceOnDevice: disk full'),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<DiskSpaceException>()),
      );
    });

    test('polkit denial becomes PermissionException', () async {
      final backend = BackendRpm(
        transport: _FailingSearchTransport(
          RpmTransportException('notAuthorized: not authorized'),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<PermissionException>()),
      );
    });

    test('unknown failures become UnknownStoreException', () async {
      final backend = BackendRpm(
        transport: _FailingSearchTransport(
          RpmTransportException('something nobody foresaw'),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<UnknownStoreException>()),
      );
    });
  });

  group('noop semantics', () {
    test('remove of a not-installed card is a noop, no transaction', () async {
      final transport = StubRpmTransport();
      final backend = BackendRpm(transport: transport);
      final terminal = await _driveToTerminal(
        await backend.remove(_id(_installId)), // vim is not installed
      );
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.noop, isTrue);
      expect(transport.removeCalls, isEmpty);
    });
  });

  group('rpm handle', () {
    RpmOperationHandle _handle(
      StreamController<RpmTxEvent> controller, {
      bool emptySuccessIsNoop = false,
      Duration heartbeatInterval = const Duration(seconds: 60),
    }) => RpmOperationHandle(
      app: _id(_installId),
      kind: OperationKind.install,
      transaction: RpmTransaction(
        events: controller.stream,
        cancel: () async => controller.close(),
      ),
      mapError: (e) =>
          UnknownStoreException(debugDetail: e.message, backendId: 'rpm'),
      emptySuccessIsNoop: emptySuccessIsNoop,
      heartbeatInterval: heartbeatInterval,
    );

    test(
      'heartbeat re-emits a silent downloading phase; stops at terminal',
      () async {
        final controller = StreamController<RpmTxEvent>();
        final handle = _handle(
          controller,
          heartbeatInterval: const Duration(milliseconds: 60),
        );
        final states = <OperationState>[];
        final sub = handle.state.listen(states.add);
        final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

        controller.add(
          const RpmTxProgress(status: RpmTxStatus.download, percentage: 42),
        );
        // Silent phase: no transport events for well over the interval.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        controller.add(const RpmTxDone(outcome: RpmTxOutcome.success));
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
      },
    );

    test('waitingForAuth progress emits Authenticating', () async {
      final controller = StreamController<RpmTxEvent>();
      final handle = _handle(controller);
      final states = <OperationState>[];
      final sub = handle.state.listen(states.add);
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

      controller.add(
        const RpmTxProgress(status: RpmTxStatus.waitingForAuth, percentage: 0),
      );
      controller.add(
        const RpmTxProgress(status: RpmTxStatus.install, percentage: 0),
      );
      controller.add(const RpmTxDone(outcome: RpmTxOutcome.success));
      await controller.close();

      final terminal = await terminalFuture.timeout(
        const Duration(seconds: 10),
      );
      await sub.cancel();

      expect(states.any((s) => s is Authenticating), isTrue);
      expect(terminal, isA<Done>());
    });

    test('update with nothing to update ends Done(noop: true)', () async {
      final transport = StubRpmTransport()..emptyUpdateIds.add(_installId);
      final backend = BackendRpm(transport: transport);
      final states = <OperationState>[];
      final handle = await backend.update(_id(_installId));
      final sub = handle.state.listen(states.add);
      final terminal = await _driveToTerminal(handle);
      await sub.cancel();
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.noop, isTrue);
      // DAG-legal bridge: preparing → applying → done(noop).
      expect(states.any((s) => s is Applying), isTrue);
    });
  });
}
