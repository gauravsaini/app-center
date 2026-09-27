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
