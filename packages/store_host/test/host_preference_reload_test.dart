/// Leaf B tests: the source-preference reload contract and the
/// runtime identity-flag toggle (docs/architecture/phase3-slice4.md).
///
/// Test-only doubles; never touch the live system.
library;

import 'dart:io';

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

const _firefoxCanonical = CanonicalAppId(
  CanonicalIdScheme.appstream,
  'org.mozilla.firefox',
);

/// Backend returning a canned firefox [AppInfo] (fixture identity +
/// seed-matching signals, like host_identity_merge_test.dart's stub)
/// from both search and the installed listing.
class _FirefoxStub extends StoreBackend {
  _FirefoxStub(this.backendId);

  final String backendId;

  @override
  String get id => backendId;

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {BackendCapability.search};

  @override
  Future<bool> isAvailable() async => true;

  AppInfo get firefox => AppInfo(
    identity: AppIdentity(backendId: backendId, nativeId: 'firefox'),
    name: 'Firefox',
    summary: '',
    iconUrl: '',
    source: AppSource.unknown,
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

const _stubIds = ['snap', 'deb'];

/// Host over the firefox stubs. Keeps the [MapFeatureFlags] handle so
/// the test can flip flags at runtime (no restart anywhere).
(StoreHost, MapFeatureFlags) _makeHost({
  required String prefsPath,
  bool identityOn = true,
}) {
  final flags = MapFeatureFlags({
    for (final id in _stubIds) 'backend.$id.enabled': true,
    'phase3.identity.enabled': identityOn,
  });
  final host = StoreHost(flags: flags, sourcePreferencesPath: prefsPath);
  for (final id in _stubIds) {
    host.registerBackend(_FirefoxStub(id));
  }
  return (host, flags);
}

void main() {
  group('preference reload contract (phase3-slice4.md)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pref-reload-test');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    String prefsPath() => '${tmp.path}/source-preferences.json';

    test('set → reload → read back: value round-trips through disk', () async {
      final (host, _) = _makeHost(prefsPath: prefsPath());
      await host.setPreferredSource(_firefoxCanonical, 'deb');
      host.reloadSourcePreferences();
      // Rebuilt from disk: the value survives the drop.
      expect(await host.getPreferredSource(_firefoxCanonical), 'deb');
      final result = await host.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'deb');
    });

    test('external file edit → reload → new value visible', () async {
      final path = prefsPath();
      final (host, _) = _makeHost(prefsPath: path);
      await host.setPreferredSource(_firefoxCanonical, 'deb');
      // Someone (or something) else rewrites the file on disk.
      await File(
        path,
      ).writeAsString('{"appstream:org.mozilla.firefox":"snap"}');
      // Cache is stale until reload.
      expect(await host.getPreferredSource(_firefoxCanonical), 'deb');
      host.reloadSourcePreferences();
      expect(await host.getPreferredSource(_firefoxCanonical), 'snap');
      final result = await host.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'snap');
    });

    test('corrupt file → reload → empty, never throws', () async {
      final path = prefsPath();
      final (host, _) = _makeHost(prefsPath: path);
      await host.setPreferredSource(_firefoxCanonical, 'deb');
      await File(path).writeAsString('not json {{{');
      expect(() => host.reloadSourcePreferences(), returnsNormally);
      expect(await host.getPreferredSource(_firefoxCanonical), isNull);
      // Forgiveness = ordering falls back to catalog.backend_order.
      final result = await host.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'snap');
    });

    test(
      'setPreferredSource → immediate getPreferredSource consistent, no reload',
      () async {
        final (host, _) = _makeHost(prefsPath: prefsPath());
        expect(await host.getPreferredSource(_firefoxCanonical), isNull);
        await host.setPreferredSource(_firefoxCanonical, 'deb');
        // Write-through + in-memory atomic: visible right away.
        expect(await host.getPreferredSource(_firefoxCanonical), 'deb');
        final result = await host.installedDetailed();
        expect(result.apps.single.preferred.identity.backendId, 'deb');
      },
    );

    test('preference survives the index reload path', () async {
      final (host, _) = _makeHost(prefsPath: prefsPath());
      await host.setPreferredSource(_firefoxCanonical, 'deb');
      host.reloadIdentityIndex();
      // Independent caches: the index drop must not clobber prefs.
      expect(await host.getPreferredSource(_firefoxCanonical), 'deb');
      final result = await host.installedDetailed();
      expect(result.apps.single.preferred.identity.backendId, 'deb');
    });
  });

  group('runtime identity toggle (phase3-slice4.md)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('toggle-test');
    });
    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test(
      'flag off → unmerged, flag on → merged, flag off → unmerged, no restart',
      () async {
        final path = '${tmp.path}/source-preferences.json';
        final (host, flags) = _makeHost(prefsPath: path, identityOn: false);

        // Off: per-backend grouping, exactly the v1 behavior.
        var cards = await host.search('firefox').toList();
        expect(cards, hasLength(2));
        expect(cards.every((c) => c.canonicalId == null), isTrue);
        expect(cards.every((c) => c.variants.length == 1), isTrue);

        // On: the very next call resolves and merges — no restart,
        // no host-side invalidation.
        flags.setFlag('phase3.identity.enabled', true);
        cards = await host.search('firefox').toList();
        expect(cards, hasLength(1));
        final card = cards.single;
        expect(card.groupId, 'appstream:org.mozilla.firefox');
        expect(card.canonicalId, _firefoxCanonical);
        expect(card.variants, hasLength(2));

        // Off again: unmerged again — nothing cached across the flip.
        flags.setFlag('phase3.identity.enabled', false);
        cards = await host.search('firefox').toList();
        expect(cards, hasLength(2));
        expect(cards.every((c) => c.canonicalId == null), isTrue);
      },
    );

    test('installedDetailed honors the same runtime toggle', () async {
      final path = '${tmp.path}/source-preferences.json';
      final (host, flags) = _makeHost(prefsPath: path, identityOn: false);

      var result = await host.installedDetailed();
      expect(result.apps, hasLength(2));

      flags.setFlag('phase3.identity.enabled', true);
      result = await host.installedDetailed();
      expect(result.apps, hasLength(1));
      expect(result.apps.single.canonicalId, _firefoxCanonical);

      flags.setFlag('phase3.identity.enabled', false);
      result = await host.installedDetailed();
      expect(result.apps, hasLength(2));
    });

    test('preference applies the moment the flag flips on', () async {
      final path = '${tmp.path}/source-preferences.json';
      final (host, flags) = _makeHost(prefsPath: path, identityOn: false);
      // Set while the flag is off (backend_order ranks snap first).
      await host.setPreferredSource(_firefoxCanonical, 'deb');
      flags.setFlag('phase3.identity.enabled', true);
      final cards = await host.search('firefox').toList();
      expect(cards, hasLength(1));
      // Rule 2 (user preference) beats rule 3 (backend_order).
      expect(cards.single.preferred.identity.backendId, 'deb');
    });
  });
}
