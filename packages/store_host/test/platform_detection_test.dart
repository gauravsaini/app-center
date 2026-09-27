/// Platform detection engine tests
/// (docs/architecture/platform-detection.md §9).
///
/// Pure Dart: fake [PlatformInfo] values and content-override readers —
/// no live system, no `/etc/os-release` reads.
library;

import 'dart:async';

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

import 'stub_backends.dart';

/// Lets async deliveries land. Zero-duration: not a sleep, just
/// event-loop turns.
Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

const _ubuntu = '''
NAME="Ubuntu"
VERSION="24.04.2 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.2 LTS"
''';

const _debianNoIdLike = '''
NAME="Debian GNU/Linux"
ID=debian
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
''';

const _fedora = '''
NAME="Fedora Linux"
ID=fedora
ID_LIKE=""
PRETTY_NAME="Fedora Linux 41 (Workstation Edition)"
''';

const _opensuseLeap = '''
NAME="openSUSE Leap"
ID="opensuse-leap"
ID_LIKE="suse opensuse"
PRETTY_NAME="openSUSE Leap 15.6"
''';

const _arch = '''
NAME="Arch Linux"
ID=arch
PRETTY_NAME="Arch Linux"
''';

const _manjaro = '''
NAME="Manjaro Linux"
ID=manjaro
ID_LIKE=arch
PRETTY_NAME="Manjaro Linux"
''';

const _fedoraPlatform = PlatformInfo(
  id: 'fedora',
  idLike: ['fedora'],
  prettyName: 'Fedora Linux',
);
const _archPlatform = PlatformInfo(
  id: 'arch',
  idLike: ['arch'],
  prettyName: 'Arch Linux',
);
const _debianPlatform = PlatformInfo(
  id: 'ubuntu',
  idLike: ['debian'],
  prettyName: 'Ubuntu',
);

/// Stub with a configurable backend id (StubSnapBackend is 'snap').
class _IdBackend extends StubSnapBackend {
  _IdBackend(this.backendId);

  final String backendId;

  @override
  String get id => backendId;

  @override
  Future<bool> isAvailable() async => true;
}

void main() {
  group('detectPlatform', () {
    test('ubuntu content -> debian-like', () {
      final p = detectPlatform(reader: () => _ubuntu);
      expect(p.id, 'ubuntu');
      expect(p.idLike, ['debian']);
      expect(p.prettyName, 'Ubuntu 24.04.2 LTS');
      expect(p.isDebianLike, isTrue);
      expect(p.isFedoraLike, isFalse);
      expect(p.isArchLike, isFalse);
      expect(p.isUnknown, isFalse);
    });

    test('debian with no ID_LIKE -> debian-like (rule 1 covers bare ID)', () {
      final p = detectPlatform(reader: () => _debianNoIdLike);
      expect(p.isDebianLike, isTrue);
      expect(p.isUnknown, isFalse);
    });

    test('fedora and opensuse-leap -> fedora-like', () {
      final fedora = detectPlatform(reader: () => _fedora);
      expect(fedora.isFedoraLike, isTrue);
      expect(fedora.isUnknown, isFalse);

      final leap = detectPlatform(reader: () => _opensuseLeap);
      expect(leap.isFedoraLike, isTrue);
      expect(leap.isUnknown, isFalse);
    });

    test('arch and manjaro -> arch-like', () {
      expect(detectPlatform(reader: () => _arch).isArchLike, isTrue);
      expect(detectPlatform(reader: () => _manjaro).isArchLike, isTrue);
    });

    test('missing file, empty, garbage, no ID= -> unknown, never throws', () {
      for (final reader in <OsReleaseReader>[
        () => null,
        () => '',
        () => 'hello\n',
        () => 'NAME="No ID here"\nPRETTY_NAME="Mystery"\n',
      ]) {
        final p = detectPlatform(reader: reader);
        expect(p.isUnknown, isTrue);
        expect(p.id, isEmpty);
      }
    });

    test(
      'rule order: ID_LIKE="debian fedora" -> debian-like (rule 1 first)',
      () {
        final p = detectPlatform(
          reader: () => 'ID=noble\nID_LIKE="debian fedora"\n',
        );
        expect(p.isDebianLike, isTrue);
        expect(p.isFedoraLike, isFalse);
        expect(p.isArchLike, isFalse);
        expect(p.isUnknown, isFalse);
      },
    );
  });

  group('seedPlatformBackendDefaults', () {
    test('debian-like -> today\'s defaults preserved', () {
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _debianPlatform);
      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.isEnabled('backend.deb.enabled'), isTrue);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.appimage.enabled'), isFalse);
    });

    test('fedora-like -> snap and deb seeded off', () {
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _fedoraPlatform);
      expect(flags.isEnabled('backend.snap.enabled'), isFalse);
      expect(flags.isEnabled('backend.deb.enabled'), isFalse);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.appimage.enabled'), isFalse);
    });

    test('arch-like -> same seeds as fedora-like, plus pacman seeded on', () {
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _archPlatform);
      expect(flags.isEnabled('backend.snap.enabled'), isFalse);
      expect(flags.isEnabled('backend.deb.enabled'), isFalse);
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.appimage.enabled'), isFalse);
      expect(flags.isEnabled('backend.rpm.enabled'), isFalse);
      // pacman is unambiguous on Arch-like systems (the probe is
      // `pacman --version`, which only passes where pacman exists) —
      // seeded ON (research D11).
      expect(flags.isEnabled('backend.pacman.enabled'), isTrue);
    });

    test('fedora-like (not arch-like) -> pacman stays dark', () {
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _fedoraPlatform);
      expect(flags.isEnabled('backend.pacman.enabled'), isFalse);
    });

    test('setFlag always wins over the seeded pacman default', () {
      final arch = MapFeatureFlags();
      seedPlatformBackendDefaults(arch, _archPlatform);
      arch.setFlag('backend.pacman.enabled', false);
      expect(arch.isEnabled('backend.pacman.enabled'), isFalse);

      final debian = MapFeatureFlags();
      seedPlatformBackendDefaults(debian, _debianPlatform);
      debian.setFlag('backend.pacman.enabled', true);
      expect(debian.isEnabled('backend.pacman.enabled'), isTrue);
    });

    test(
      'unknown -> zero seeded keys, byte-identical to compiled defaults',
      () {
        final flags = MapFeatureFlags();
        seedPlatformBackendDefaults(flags, const PlatformInfo.unknown());
        final pristine = MapFeatureFlags();
        for (final key in [
          'backend.flatpak.enabled',
          'backend.snap.enabled',
          'backend.deb.enabled',
          'backend.appimage.enabled',
        ]) {
          expect(flags.isEnabled(key), pristine.isEnabled(key));
        }
      },
    );

    test('setFlag always wins over the seeded default', () {
      final fedora = MapFeatureFlags();
      seedPlatformBackendDefaults(fedora, _fedoraPlatform);
      fedora.setFlag('backend.snap.enabled', true);
      expect(fedora.isEnabled('backend.snap.enabled'), isTrue);

      final debian = MapFeatureFlags();
      seedPlatformBackendDefaults(debian, _debianPlatform);
      debian.setFlag('backend.snap.enabled', false);
      expect(debian.isEnabled('backend.snap.enabled'), isFalse);
    });
  });

  group('MapFeatureFlags.seedDefault', () {
    test('emits no changes event; setFlag does', () async {
      final flags = MapFeatureFlags();
      final events = <String>[];
      final sub = flags.changes.listen(events.add);

      flags.seedDefault('backend.snap.enabled', false);
      await _pump();
      expect(events, isEmpty);

      flags.setFlag('backend.snap.enabled', false);
      await _pump();
      expect(events, ['backend.snap.enabled']);

      await sub.cancel();
    });
  });

  group('StoreHost with seeded platform defaults', () {
    StoreHost fedoraHost() {
      final flags = MapFeatureFlags();
      seedPlatformBackendDefaults(flags, _fedoraPlatform);
      return StoreHost(flags: flags)
        ..registerBackend(_IdBackend('snap'))
        ..registerBackend(_IdBackend('deb'))
        ..registerBackend(_IdBackend('flatpak'));
    }

    test('fedora seed: snap and deb excluded, flatpak included', () async {
      final host = fedoraHost();
      final backends = await host.enabledBackends();
      expect(backends.map((b) => b.id), ['flatpak']);
    });

    test(
      'enqueue on a seeded-off backend throws BackendUnavailableException',
      () async {
        final host = fedoraHost();
        expect(
          () => host.enqueue(
            OperationKind.install,
            const AppIdentity(backendId: 'snap', nativeId: 'x'),
          ),
          throwsA(isA<BackendUnavailableException>()),
        );
      },
    );

    test(
      'unknown seed: identical backend set to today\'s buildStoreHost',
      () async {
        StoreHost hostWith(MapFeatureFlags flags) => StoreHost(flags: flags)
          ..registerBackend(_IdBackend('snap'))
          ..registerBackend(_IdBackend('deb'))
          ..registerBackend(_IdBackend('flatpak'));

        final seeded = MapFeatureFlags();
        seedPlatformBackendDefaults(seeded, const PlatformInfo.unknown());
        final seededIds = (await hostWith(
          seeded,
        ).enabledBackends()).map((b) => b.id);
        final pristineIds = (await hostWith(
          MapFeatureFlags(),
        ).enabledBackends()).map((b) => b.id);
        expect(seededIds, pristineIds);
        expect(seededIds, ['snap', 'deb', 'flatpak']);
      },
    );
  });
}
