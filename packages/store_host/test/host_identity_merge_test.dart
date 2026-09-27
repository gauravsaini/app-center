/// Host-side identity merge + source-preference store tests
/// (docs/architecture/phase3-slice2.md §3, §4, §6).
///
/// Firefox across snap/deb/flatpak/rpm/pacman — fixture identities +
/// harvested signals against the bundled seed — must merge into ONE
/// [UnifiedApp] with `canonicalId == appstream:org.mozilla.firefox`.
/// Test-only doubles; never touch the live system.
library;

import 'dart:io';

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

const _firefoxCanonical = CanonicalAppId(
  CanonicalIdScheme.appstream,
  'org.mozilla.firefox',
);

/// A backend returning a canned firefox [AppInfo] (fixture identity +
/// harvested signals, matching the bundled seed) from both search and
/// the installed listing. The rpm/deb/snap/pacman native id is
/// `firefox`; flatpak's is the verbatim AppStream id.
class StubFirefoxBackend extends StoreBackend {
  StubFirefoxBackend({required this.backendId, this.installedVersion});

  final String backendId;
  final String? installedVersion;

  @override
  String get id => backendId;

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {BackendCapability.search};

  @override
  Future<bool> isAvailable() async => true;

  String get _nativeId =>
      backendId == 'flatpak' ? 'org.mozilla.firefox' : 'firefox';

  AppInfo get firefox => AppInfo(
    identity: AppIdentity(backendId: backendId, nativeId: _nativeId),
    name: 'Firefox',
    summary: '',
    iconUrl: '',
    source: AppSource.unknown,
    installedVersion: installedVersion,
    identitySignal: const IdentitySignal(
      appstreamId: 'org.mozilla.firefox',
      homepageUrl: 'https://www.mozilla.org/firefox/',
    ),
  );

  @override
  Stream<AppInfo> search(String query) => Stream.value(firefox);

  @override
  Future<List<AppInfo>> listInstalled() async => [firefox];

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> install(AppIdentity app) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> remove(AppIdentity app) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> update(AppIdentity app) =>
      throw UnimplementedError('stub');

  @override
  Future<List<UpdateInfo>> checkUpdates() async => const [];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}

/// A backend returning an app nothing resolves — no seed entry, no
/// signals — proving unresolved apps keep the v1 grouping bit for bit.
class StubUnknownBackend extends StubFirefoxBackend {
  StubUnknownBackend() : super(backendId: 'snap');

  @override
  AppInfo get firefox => AppInfo(
    identity: const AppIdentity(backendId: 'snap', nativeId: 'weird-thing'),
    name: 'Weird Thing',
    summary: '',
    iconUrl: '',
    source: AppSource.unknown,
  );
}

const _backendIds = ['snap', 'deb', 'flatpak', 'rpm', 'pacman'];

/// Host with the five firefox backends registered. [installedBackend]
/// marks that backend's firefox as installed (HLD §6 rule 1).
/// [prefsPath] overrides the source-preferences file (hermetic tests).
StoreHost makeIdentityHost({
  Map<String, Object>? flags,
  String? installedBackend,
  String? prefsPath,
}) {
  final merged = <String, Object>{
    for (final id in _backendIds) 'backend.$id.enabled': true,
    'phase3.identity.enabled': true,
    ...?flags,
  };
  final host = StoreHost(
    flags: MapFeatureFlags(merged),
    sourcePreferencesPath: prefsPath,
  );
  for (final id in _backendIds) {
    host.registerBackend(
      StubFirefoxBackend(
        backendId: id,
        installedVersion: id == installedBackend ? '1.0' : null,
      ),
    );
  }
  return host;
}

void main() {
  group('host identity merge (phase3-slice2 §3)', () {
    test(
      'firefox across five backends merges into one canonical card',
      () async {
        final host = makeIdentityHost();
        final result = await host.installedDetailed();
        expect(result.apps, hasLength(1));
        final card = result.apps.single;
        expect(card.groupId, 'appstream:org.mozilla.firefox');
        expect(card.canonicalId, _firefoxCanonical);
        expect(card.variants, hasLength(5));
        expect(
          card.variants.map((v) => v.identity.backendId).toSet(),
          _backendIds.toSet(),
        );
        // No installed variant, no preference: catalog.backend_order
        // ('flatpak,snap,deb,appimage,rpm,pacman') decides.
        expect(card.preferred.identity.backendId, 'flatpak');
      },
    );

    test('search merges variants across backends into one card', () async {
      final host = makeIdentityHost();
      final cards = await host.search('firefox').toList();
      expect(cards, hasLength(1));
      final card = cards.single;
      expect(card.groupId, 'appstream:org.mozilla.firefox');
      expect(card.canonicalId, _firefoxCanonical);
      expect(card.variants, hasLength(5));
    });

    test('installed source wins over backend_order (HLD §6 rule 1)', () async {
      final host = makeIdentityHost(installedBackend: 'rpm');
      final result = await host.installedDetailed();
      final card = result.apps.single;
      expect(card.groupId, 'appstream:org.mozilla.firefox');
      expect(card.preferred.identity.backendId, 'rpm');
      expect(card.preferred.installedVersion, '1.0');
    });

    test(
      'installed() keeps its signature over the merged detailed path',
      () async {
        final host = makeIdentityHost();
        final cards = await host.installed();
        expect(cards, hasLength(1));
        expect(cards.single.canonicalId, _firefoxCanonical);
      },
    );

    test('unresolved app keeps v1 grouping with null canonicalId', () async {
      final host = StoreHost(
        flags: MapFeatureFlags({
          'backend.snap.enabled': true,
          'phase3.identity.enabled': true,
        }),
      );
      host.registerBackend(StubUnknownBackend());
      final result = await host.installedDetailed();
      expect(result.apps, hasLength(1));
      final card = result.apps.single;
      expect(card.groupId, 'snap:weird-thing');
      expect(card.canonicalId, isNull);
      expect(card.variants, hasLength(1));
    });

    test('flag off keeps today\'s per-backend grouping bit for bit', () async {
      final host = makeIdentityHost(flags: {'phase3.identity.enabled': false});
      final cards = await host.installed();
      expect(cards.map((c) => c.groupId).toSet(), {
        'snap:firefox',
        'deb:firefox',
        'flatpak:org.mozilla.firefox',
        'rpm:firefox',
        'pacman:firefox',
      });
      expect(cards.every((c) => c.canonicalId == null), isTrue);
      expect(cards.every((c) => c.variants.length == 1), isTrue);
    });

    test('flag off search emits one card per backend result', () async {
      final host = makeIdentityHost(flags: {'phase3.identity.enabled': false});
      final cards = await host.search('firefox').toList();
      expect(cards, hasLength(5));
      expect(cards.every((c) => c.canonicalId == null), isTrue);
    });
  });

  group('source preference store (phase3-slice2 §4)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('source-prefs-test');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    String prefsPath() => '${tmp.path}/source-preferences.json';

    test('setPreferredSource reorders variants (HLD §6 rule 2)', () async {
      final host = makeIdentityHost(prefsPath: prefsPath());
      await host.setPreferredSource(_firefoxCanonical, 'deb');
      final result = await host.installedDetailed();
      final card = result.apps.single;
      expect(card.preferred.identity.backendId, 'deb');
    });

    test('preference persists across host instances', () async {
      final path = prefsPath();
      final host = makeIdentityHost(prefsPath: path);
      await host.setPreferredSource(_firefoxCanonical, 'pacman');
      final host2 = makeIdentityHost(prefsPath: path);
      final result = await host2.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'pacman');
    });

    test(
      'installed source still beats user preference (rule 1 > rule 2)',
      () async {
        final host = makeIdentityHost(
          installedBackend: 'rpm',
          prefsPath: prefsPath(),
        );
        await host.setPreferredSource(_firefoxCanonical, 'deb');
        final result = await host.installedDetailed();
        expect(result.apps.single.preferred.identity.backendId, 'rpm');
      },
    );

    test(
      'unknown backend id is stored verbatim, ignored at ordering',
      () async {
        final host = makeIdentityHost(prefsPath: prefsPath());
        await host.setPreferredSource(_firefoxCanonical, 'no-such-backend');
        final result = await host.installedDetailed();
        final card = result.apps.single;
        // Falls through to catalog.backend_order: flatpak first.
        expect(card.preferred.identity.backendId, 'flatpak');
        // And the file really holds the unknown id verbatim.
        final raw = await File(prefsPath()).readAsString();
        expect(raw, contains('"no-such-backend"'));
      },
    );

    test('corrupt preferences file loads empty, never throws', () async {
      final path = prefsPath();
      await File(path).writeAsString('not json {{{');
      final host = makeIdentityHost(prefsPath: path);
      final result = await host.installedDetailed();
      // Corrupt → empty preferences → backend_order fallback.
      expect(result.apps.single.preferred.identity.backendId, 'flatpak');
    });

    test('missing preferences file loads empty, never throws', () async {
      final host = makeIdentityHost(prefsPath: prefsPath());
      // No file written at all — host must not throw on load.
      final result = await host.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'flatpak');
    });

    test('non-map JSON is skipped, never throws', () async {
      final path = prefsPath();
      await File(path).writeAsString('["a", "list"]');
      final host = makeIdentityHost(prefsPath: path);
      final result = await host.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'flatpak');
    });
  });
}
