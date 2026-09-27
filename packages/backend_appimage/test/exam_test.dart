import 'dart:convert';

import 'package:backend_appimage/backend_appimage.dart';
import 'package:backend_appimage/testing.dart';
import 'package:store_contracts/exam.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

const _shaA = StubAppimageTransport.installTargetSha;
const _shaB = StubAppimageTransport.installedTargetSha;
const _unknownSha =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

BackendAppimage _create() =>
    BackendAppimage(transport: StubAppimageTransport());

AppIdentity _id(String sha) =>
    AppIdentity(backendId: 'appimage', nativeId: sha);

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

void main() {
  group('appimage backend', () {
    test('passes the full contract exam', () async {
      await runContractExam(
        'appimage',
        _create,
        installTarget: _id(_shaA),
        unknownTarget: _id(_unknownSha),
        installedTarget: _id(_shaB),
      );
    });

    test('capabilities are exactly search/details/install/remove', () {
      final backend = _create();
      expect(backend.id, 'appimage');
      expect(backend.contractVersion, storeContractsMajor);
      expect(backend.capabilities, {
        BackendCapability.search,
        BackendCapability.details,
        BackendCapability.install,
        BackendCapability.remove,
      });
    });

    test('checkUpdates and recoverInFlight are honest empties', () async {
      final backend = _create();
      expect(await backend.checkUpdates(), isEmpty);
      expect(await backend.recoverInFlight(), isEmpty);
    });

    test('listInstalled reports scanned AppImages, rejects decoys', () async {
      final backend = _create();
      final apps = await backend.listInstalled();
      // Two real AppImages; notes.txt (no magic) and the ELF-without-magic
      // decoy binary are rejected.
      expect(apps, hasLength(2));
      for (final app in apps) {
        expect(app.identity.backendId, 'appimage');
        expect(app.source, AppSource.appImage);
        expect(app.isInstalled, isTrue);
      }
      final bySha = {for (final a in apps) a.identity.nativeId: a};
      expect(bySha[_shaA]!.name, 'TestApp');
      expect(bySha[_shaA]!.installedVersion, '1.2.3');
      expect(bySha[_shaB]!.name, 'ManagedApp');
      expect(bySha[_shaB]!.installedVersion, '2.0');
    });

    test(
      'getDetails resolves desktop metadata with version precedence',
      () async {
        final backend = _create();
        final details = await backend.getDetails(_id(_shaA));
        expect(details.app.name, 'Test App'); // from the .desktop, not filename
        // X-AppImage-Version (9.9.9) beats the filename version (1.2.3).
        expect(details.app.version, '9.9.9');
        expect(details.app.installedVersion, '9.9.9');
        expect(details.app.source, AppSource.appImage);
        expect(
          details.description,
          startsWith("Runs unsandboxed with your user's full privileges. "),
        );
        expect(details.description, contains('A test AppImage'));
        expect(details.app.iconUrl, endsWith('/$_shaA.png'));
        expect(details.permissions, isEmpty);
      },
    );

    test('getDetails on an unknown id throws typed', () async {
      final backend = _create();
      expect(
        () => backend.getDetails(_id(_unknownSha)),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('search matches name and filename, case-insensitively', () async {
      final backend = _create();
      Future<List<AppInfo>> collect(String q) => backend.search(q).toList();
      final all = await collect('app');
      expect(all.map((a) => a.identity.nativeId).toSet(), {_shaA, _shaB});
      final managed = await collect('MANAGED');
      expect(managed.map((a) => a.identity.nativeId), [_shaB]);
      expect(await collect('zzz-no-such-app'), isEmpty);
    });

    test(
      'install adopt flow copies, integrates, and writes a manifest',
      () async {
        final transport = StubAppimageTransport();
        final backend = BackendAppimage(transport: transport);
        final home = transport.home;
        final terminal = await _driveToTerminal(
          await backend.install(_id(_shaA)),
        );
        expect(terminal, isA<Done>());
        // Desktop X-AppImage-Version wins for the installed version.
        expect((terminal as Done).result.installedVersion, '9.9.9');
        expect(transport.exists('$home/Applications/testapp.AppImage'), isTrue);
        final desktopPath =
            '$home/.local/share/applications/appimage-testapp.desktop';
        expect(transport.exists(desktopPath), isTrue);
        expect(
          transport.exists(
            '$home/.local/share/libreapp-center/appimage/$_shaA.json',
          ),
          isTrue,
        );
        final desktop = utf8.decode(
          await transport.readHead(desktopPath, 4096),
        );
        expect(
          desktop,
          contains('Exec="$home/Applications/testapp.AppImage" %U'),
        );
        expect(desktop, contains('X-LibreStore-Identity=$_shaA'));
        expect(desktop, contains('X-LibreStore-Managed=true'));
        expect(desktop, contains('X-LibreStore-Backend=appimage'));
        // Icon cached under the content hash.
        expect(
          transport.exists(
            '$home/.cache/libreapp-center/appimage-icons/$_shaA.png',
          ),
          isTrue,
        );
      },
    );

    test('second install of a managed app is an idempotent noop', () async {
      final transport = StubAppimageTransport();
      final backend = BackendAppimage(transport: transport);
      await _driveToTerminal(await backend.install(_id(_shaA)));
      final terminal = await _driveToTerminal(
        await backend.install(_id(_shaA)),
      );
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.noop, isTrue);
    });

    test(
      'cancel mid-copy lands on Cancelled and deletes partial work',
      () async {
        final transport = StubAppimageTransport();
        final backend = BackendAppimage(transport: transport);
        final home = transport.home;
        final handle = await backend.install(_id(_shaA));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (handle.current is! Applying) {
          if (DateTime.now().isAfter(deadline)) {
            fail('never reached Applying');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await handle.cancel();
        final terminal = await _driveToTerminal(handle);
        // Never a bare Failed for a user cancel.
        expect(terminal, isA<Cancelled>());
        // Partial copy rolled back; desktop entry and manifest never landed.
        expect(
          transport.exists('$home/Applications/testapp.AppImage'),
          isFalse,
        );
        expect(
          transport.exists(
            '$home/.local/share/applications/appimage-testapp.desktop',
          ),
          isFalse,
        );
        expect(
          transport.exists(
            '$home/.local/share/libreapp-center/appimage/$_shaA.json',
          ),
          isFalse,
        );
      },
    );

    test('remove deletes managed files but keeps the user original '
        'when it was integrated in place', () async {
      final transport = StubAppimageTransport();
      final backend = BackendAppimage(transport: transport);
      final home = transport.home;
      final terminal = await _driveToTerminal(await backend.remove(_id(_shaB)));
      expect(terminal, isA<Done>());
      expect(
        transport.exists(
          '$home/.local/share/libreapp-center/appimage/$_shaB.json',
        ),
        isFalse,
      );
      // copied:false in the fixture manifest → the original is untouched.
      expect(
        transport.exists('$home/Applications/ManagedApp-2.0-x86_64.AppImage'),
        isTrue,
      );
    });

    test('remove of an unknown id throws typed', () async {
      final backend = _create();
      expect(
        () => backend.remove(_id(_unknownSha)),
        throwsA(isA<AppNotFoundException>()),
      );
    });
  });

  group('magic classifier', () {
    List<int> head(int aiByte) => [
      0x7F, 0x45, 0x4C, 0x46, // ELF
      0x02, 0x01, 0x01, 0x00,
      0x41, 0x49, aiByte, // 'AI' + type byte
      0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    test('accepts type 1 and type 2', () {
      expect(isAppImageMagic(head(0x02)), isTrue);
      expect(isAppImageMagic(head(0x01)), isTrue);
    });

    test('rejects ELF without AppImage magic, garbage, and short reads', () {
      expect(isAppImageMagic(head(0x00)), isFalse);
      expect(isAppImageMagic(List<int>.filled(16, 0)), isFalse);
      expect(isAppImageMagic([0x7F, 0x45, 0x4C]), isFalse);
      expect(isAppImageMagic(const []), isFalse);
    });
  });

  group('filename parser', () {
    test('parses the Name-Version-arch scheme', () {
      final m = parseFilename('Kdenlive-24.08.3-x86_64.AppImage');
      expect(m.name, 'Kdenlive');
      expect(m.version, '24.08.3');
    });

    test('drops the arch token and keeps a null version when absent', () {
      final m = parseFilename('appimagetool-x86_64.AppImage');
      expect(m.name, 'appimagetool');
      expect(m.version, isNull);
    });

    test('handles underscores, named versions, and v-prefixes', () {
      final a = parseFilename('My_Cool_App-continuous-x86_64.AppImage');
      expect(a.name, 'My Cool App');
      expect(a.version, 'continuous');

      final b = parseFilename('Foo-v1.2.3-aarch64.appimage');
      expect(b.name, 'Foo');
      expect(b.version, 'v1.2.3');
    });

    test('falls back to the bare stem when unparseable', () {
      final m = parseFilename('weirdname.AppImage');
      expect(m.name, 'weirdname');
      expect(m.version, isNull);
    });
  });

  group('desktop parser', () {
    test('reads the Desktop Entry section, skips comments', () {
      const content = '''
# a comment
[Desktop Entry]
Type=Application
Name=Foo
Comment=Bar baz

[Other]
Name=Ignored
''';
      final map = parseDesktopFile(content);
      expect(map['Name'], 'Foo');
      expect(map['Comment'], 'Bar baz');
      expect(map['Type'], 'Application');
    });

    test('returns {} for unparseable input, never throws', () {
      expect(parseDesktopFile(''), isEmpty);
      expect(parseDesktopFile('no sections here\njust lines'), isEmpty);
    });
  });

  group('version fallback', () {
    test('prefers X-AppImage-Version, then Version, then filename', () {
      expect(
        versionFallback(
          xAppImageVersion: '9.9.9',
          desktopVersion: '1.0',
          filenameVersion: '1.2.3',
        ),
        '9.9.9',
      );
      expect(
        versionFallback(desktopVersion: '1.0', filenameVersion: '1.2.3'),
        '1.0',
      );
      expect(versionFallback(filenameVersion: '1.2.3'), '1.2.3');
      expect(versionFallback(), isNull);
    });

    test('blank values are skipped, never returned', () {
      expect(
        versionFallback(xAppImageVersion: '  ', filenameVersion: '1.2.3'),
        '1.2.3',
      );
      expect(versionFallback(desktopVersion: ''), isNull);
    });
  });

  group('install manifest', () {
    test('survives a JSON round-trip', () {
      const m = InstallManifest(
        sourcePath: '/dl/A.AppImage',
        managedPath: '/home/u/Applications/a.AppImage',
        copied: true,
        desktopFile: 'appimage-a.desktop',
        iconPath: '/home/u/.cache/icons/x.png',
      );
      final rt = InstallManifest.tryParse(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>,
      );
      expect(rt, isNotNull);
      expect(rt!.sourcePath, m.sourcePath);
      expect(rt.managedPath, m.managedPath);
      expect(rt.copied, isTrue);
      expect(rt.desktopFile, m.desktopFile);
      expect(rt.iconPath, m.iconPath);
    });

    test('rejects corrupt JSON instead of throwing', () {
      expect(InstallManifest.tryParse({'copied': 'yes'}), isNull);
      expect(InstallManifest.tryParse({}), isNull);
    });
  });

  group('desktop template', () {
    test('renders provenance keys and a quoted Exec', () {
      final out = renderDesktopFile(
        name: 'Test App',
        comment: 'c',
        execPath: '/home/u/Applications/testapp.AppImage',
        iconPath: '/home/u/.cache/icons/abc.png',
        categories: 'Utility',
        sha: 'abc123',
      );
      expect(out, contains('[Desktop Entry]'));
      expect(out, contains('Type=Application'));
      expect(out, contains('Name=Test App'));
      expect(out, contains('Exec="/home/u/Applications/testapp.AppImage" %U'));
      expect(out, contains('Icon=/home/u/.cache/icons/abc.png'));
      expect(out, contains('Categories=Utility;'));
      expect(out, contains('X-LibreStore-Backend=appimage'));
      expect(out, contains('X-LibreStore-Identity=abc123'));
      expect(out, contains('X-LibreStore-Managed=true'));
    });

    test('defaults categories and tolerates a missing icon', () {
      final out = renderDesktopFile(name: 'n', execPath: '/x', sha: 's');
      expect(out, contains('Categories=Utility;'));
      expect(out, contains('Icon=\n'));
    });
  });

  group('slugify', () {
    test('lowercases, collapses separators, truncates to 48', () {
      expect(slugify('Test App!'), 'test-app');
      expect(slugify('Kdenlive'), 'kdenlive');
      expect(slugify('  --Weird__Name--  '), 'weird-name');
      expect(slugify('!!!'), 'app');
      expect(slugify('a' * 60), hasLength(48));
    });
  });
}
