import 'package:backend_flatpak/backend_flatpak.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:store_contracts/exam.dart';
import 'package:test/test.dart';

void main() {
  group('flatpak backend', () {
    test('passes the full contract exam', () async {
      await runContractExam(
        'flatpak',
        () => BackendFlatpak(transport: StubFlatpakTransport()),
        installTarget: const AppIdentity(
          backendId: 'flatpak',
          nativeId: 'org.test.App',
        ),
        unknownTarget: const AppIdentity(
          backendId: 'flatpak',
          nativeId: 'no.such.App',
        ),
        installedTarget: const AppIdentity(
          backendId: 'flatpak',
          nativeId: 'org.test.Installed',
        ),
      );
    });

    test(
      'getDetails surfaces permissions pre-install (installed app)',
      () async {
        final backend = BackendFlatpak(transport: StubFlatpakTransport());
        final details = await backend.getDetails(
          const AppIdentity(
            backendId: 'flatpak',
            nativeId: 'org.test.Installed',
          ),
        );
        final ids = details.permissions.map((p) => p.id).toSet();
        expect(ids, contains('shared=network'));
        expect(ids, contains('sockets=x11'));
        // Labels are human-readable, ids stay raw.
        final network = details.permissions.firstWhere(
          (p) => p.id == 'shared=network',
        );
        expect(network.label, 'Network access');
      },
    );

    test('ref parsing: bare id defaults, full ref round-trips', () {
      final bare = FlatpakRef.parse('org.videolan.VLC');
      expect(bare.ref, 'app/org.videolan.VLC/x86_64/stable');
      final full = FlatpakRef.parse('runtime/org.gnome.Platform/x86_64/45');
      expect(full.kind, 'runtime');
      expect(full.branch, '45');
      expect(() => FlatpakRef.parse('not a ref'), throwsFormatException);
    });
  });

  group('BackendFlatpak identity signals (phase3-slice2)', () {
    test(
      'search reports the nativeId verbatim as the appstream signal',
      () async {
        final backend = BackendFlatpak(transport: StubFlatpakTransport());
        final results = await backend.search('test').toList();
        expect(results, hasLength(1));
        final signal = results.first.identitySignal!;
        expect(signal.appstreamId, 'org.test.App');
        // No Homepage on the search wire format.
        expect(signal.homepageUrl, isNull);
      },
    );

    test('getDetails harvests Homepage + verbatim appstream id', () async {
      final backend = BackendFlatpak(transport: StubFlatpakTransport());
      final details = await backend.getDetails(
        const AppIdentity(backendId: 'flatpak', nativeId: 'org.test.App'),
      );
      expect(details.app.identitySignal!.appstreamId, 'org.test.App');
      expect(
        details.app.identitySignal!.homepageUrl,
        'https://example.com/test-app',
      );
      expect(details.homepage, 'https://example.com/test-app');
    });

    test('listInstalled reports the verbatim appstream signal', () async {
      final backend = BackendFlatpak(transport: StubFlatpakTransport());
      final apps = await backend.listInstalled();
      expect(apps, hasLength(2));
      expect(apps.first.identitySignal!.appstreamId, 'org.test.Installed');
      expect(apps[1].identitySignal!.appstreamId, 'org.test.Second');
    });
  });

  group('BackendFlatpak.listInstalled', () {
    test('parses flatpak list rows to AppInfos with versions set', () async {
      final backend = BackendFlatpak(transport: StubFlatpakTransport());
      final apps = await backend.listInstalled();
      expect(apps, hasLength(2));
      final first = apps.first;
      expect(first.identity.backendId, 'flatpak');
      expect(first.identity.nativeId, 'org.test.Installed');
      expect(first.name, 'Test Installed');
      expect(first.source, AppSource.flatpak);
      expect(first.installedVersion, '2.0');
      expect(first.isInstalled, isTrue);
      expect(apps[1].identity.nativeId, 'org.test.Second');
      expect(apps[1].installedVersion, '1.5');
      expect(apps[1].isInstalled, isTrue);
    });

    test('skips header and unparsable lines', () async {
      final backend = BackendFlatpak(transport: _NoisyFlatpakTransport());
      final apps = await backend.listInstalled();
      expect(apps.map((a) => a.identity.nativeId), ['org.test.Installed']);
    });

    test('transport failure throws a typed StoreException', () async {
      final backend = BackendFlatpak(transport: _DeadFlatpakTransport());
      expect(
        () => backend.listInstalled(),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('empty installed list returns []', () async {
      final backend = BackendFlatpak(transport: _EmptyFlatpakTransport());
      expect(await backend.listInstalled(), isEmpty);
    });
  });

  group('BackendFlatpak.checkUpdates', () {
    test('maps remote-ls rows to UpdateInfos with from/to versions', () async {
      final backend = BackendFlatpak(transport: StubFlatpakTransport());
      final updates = await backend.checkUpdates();
      expect(updates, hasLength(2));
      final first = updates.first;
      expect(first.identity.backendId, 'flatpak');
      expect(first.identity.nativeId, 'org.test.Installed');
      expect(first.name, 'Test Installed');
      expect(first.fromVersion, '2.0');
      expect(first.toVersion, '2.1');
      final second = updates[1];
      expect(second.identity.nativeId, 'org.test.Second');
      expect(second.fromVersion, '1.5');
      expect(second.toVersion, '1.6');
    });

    test('skips header and unparsable update rows', () async {
      final backend = BackendFlatpak(
        transport: _NoisyUpdatesFlatpakTransport(),
      );
      final updates = await backend.checkUpdates();
      expect(updates.map((u) => u.identity.nativeId), ['org.test.Installed']);
      expect(updates.single.toVersion, '2.1');
    });

    test('flatpak missing returns [] instead of throwing', () async {
      final backend = BackendFlatpak(transport: _DeadFlatpakTransport());
      expect(await backend.checkUpdates(), isEmpty);
    });

    test('transport failure throws a typed StoreException', () async {
      final backend = BackendFlatpak(
        transport: _BrokenUpdatesFlatpakTransport(),
      );
      expect(() => backend.checkUpdates(), throwsA(isA<StoreException>()));
    });

    test('no updates available returns []', () async {
      final backend = BackendFlatpak(transport: _NoUpdatesFlatpakTransport());
      expect(await backend.checkUpdates(), isEmpty);
    });

    test('update for unknown app has null fromVersion', () async {
      final backend = BackendFlatpak(
        transport: _UnknownAppUpdatesFlatpakTransport(),
      );
      final updates = await backend.checkUpdates();
      expect(updates, hasLength(1));
      expect(updates.single.identity.nativeId, 'org.test.Stranger');
      expect(updates.single.fromVersion, isNull);
      expect(updates.single.toVersion, '9.9');
    });
  });

  group('progress parser', () {
    test('parses percent-only lines', () {
      final p = parseProgressLine('Downloading: 45%')!;
      expect(p.percent, 45);
      expect(p.totalBytes, isNull);
    });

    test('parses percent with byte counts', () {
      final p = parseProgressLine(
        '[====>    ] Downloading: 45% (12.3 MB / 27.5 MB)',
      )!;
      expect(p.percent, 45);
      expect(p.totalBytes, greaterThan(p.doneBytes!));
      expect(p.doneBytes, closeTo(12.3 * 1024 * 1024, 1024));
    });

    test('clamps absurd percents, ignores noise', () {
      expect(parseProgressLine('Downloading: 142%')!.percent, 100);
      expect(parseProgressLine('Resolving dependencies...'), isNull);
      expect(parseProgressLine(''), isNull);
    });
  });
}

/// Mixes a header row, a valid row, and garbage: only the valid row
/// survives parsing.
class _NoisyFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'list') {
      return [
        'Application\tName\tVersion',
        'org.test.Installed\tTest Installed\t2.0',
        'this line has no reverse dns id',
        '',
      ];
    }
    return super.run(args);
  }
}

/// flatpak binary missing.
class _DeadFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'list') {
      throw FlatpakCommandException(args, 127, 'command not found');
    }
    return super.run(args);
  }
}

/// Nothing installed.
class _EmptyFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'list') return const [];
    return super.run(args);
  }
}

/// Mixes a header row, a valid update row, and garbage in
/// `remote-ls --updates`: only the valid row survives parsing.
class _NoisyUpdatesFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'remote-ls') {
      return [
        'Application\tName\tVersion',
        'org.test.Installed\tTest Installed\t2.1',
        'this line has no reverse dns id',
      ];
    }
    return super.run(args);
  }
}

/// `remote-ls` fails with a non-127 error: the backend must surface a
/// typed StoreException, not a raw crash.
class _BrokenUpdatesFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'remote-ls') {
      throw FlatpakCommandException(args, 1, 'boom');
    }
    return super.run(args);
  }
}

/// No updates available on the remote.
class _NoUpdatesFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'remote-ls') return const [];
    return super.run(args);
  }
}

/// Remote offers an update for an app that is not installed locally:
/// fromVersion is null, never a crash.
class _UnknownAppUpdatesFlatpakTransport extends StubFlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == 'remote-ls') {
      return ['org.test.Stranger\tStranger App\t9.9'];
    }
    return super.run(args);
  }
}
