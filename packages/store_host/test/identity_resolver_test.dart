/// [IdentityResolver] tests (phase3-identity-lld.md §7).
///
/// Seed-loaded: the same app (Firefox) as snap/deb/flatpak/rpm/pacman
/// identities resolves to ONE canonical id. The rpm/pacman identities
/// use realistic version-pinned nativeIds — the fakes below mirror the
/// REAL `identityLookupKey` overrides in packages/backend_rpm and
/// packages/backend_pacman (commit f101d904: name token, total
/// function); real instances need CLI transports, hence fakes here.
/// snap/deb/flatpak fakes keep the additive default (nativeId
/// unchanged).
library;

import 'dart:convert';

import 'package:store_host/src/identity/seed_index.dart';
import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

/// Minimal [StoreBackend] fake: only [identityLookupKey] differs from
/// the contract default. Everything else throws — the resolver never
/// calls it.
class _FakeBackend extends StoreBackend {
  _FakeBackend(this.backendId, {this.keyFor});

  final String backendId;

  /// Lookup-key override under test, or the contract default when null.
  final String Function(AppIdentity id)? keyFor;

  @override
  String get id => backendId;

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {};

  @override
  Future<bool> isAvailable() => throw UnimplementedError('_FakeBackend');

  @override
  Stream<AppInfo> search(String query) =>
      throw UnimplementedError('_FakeBackend');

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('_FakeBackend');

  @override
  Future<OperationHandle> install(AppIdentity id) =>
      throw UnimplementedError('_FakeBackend');

  @override
  Future<OperationHandle> remove(AppIdentity id) =>
      throw UnimplementedError('_FakeBackend');

  @override
  Future<OperationHandle> update(AppIdentity id) =>
      throw UnimplementedError('_FakeBackend');

  @override
  Future<List<UpdateInfo>> checkUpdates() =>
      throw UnimplementedError('_FakeBackend');

  @override
  Future<List<OperationHandle>> recoverInFlight() =>
      throw UnimplementedError('_FakeBackend');

  @override
  String identityLookupKey(AppIdentity identity) =>
      keyFor?.call(identity) ?? super.identityLookupKey(identity);
}

/// Preview of the rpm override (LLD §3; real impl in
/// packages/backend_rpm, commit f101d904): 5-token nativeId →
/// arch/version-agnostic package name. Defensive: never throws, falls
/// back to the raw nativeId.
String _rpmKey(AppIdentity identity) {
  final native = identity.nativeId;
  final semi = native.indexOf(';');
  if (semi < 0) return native;
  final name = native.substring(0, semi);
  return name.isEmpty ? native : name;
}

/// Preview of the pacman override (LLD §3; real impl in
/// packages/backend_pacman, commit f101d904): `name;version;arch;repo`
/// → name token.
String _pacmanKey(AppIdentity identity) {
  final native = identity.nativeId;
  final semi = native.indexOf(';');
  if (semi < 0) return native;
  final name = native.substring(0, semi);
  return name.isEmpty ? native : name;
}

/// A resolver wired to the REAL bundled seed with one fake backend per
/// format. snap/deb/flatpak use the additive default lookup key;
/// rpm/pacman use the name-token previews.
IdentityResolver _seededResolver() {
  final decoded = jsonDecode(kIdentitySeedJson);
  final index = IdentityIndex.fromJsonDocs([
    Map<String, Object?>.from(decoded as Map),
  ]);
  return IdentityResolver(
    index: index,
    backends: {
      'snap': _FakeBackend('snap'),
      'deb': _FakeBackend('deb'),
      'flatpak': _FakeBackend('flatpak'),
      'rpm': _FakeBackend('rpm', keyFor: _rpmKey),
      'pacman': _FakeBackend('pacman', keyFor: _pacmanKey),
    },
  );
}

void main() {
  group('seed-loaded resolver', () {
    late IdentityResolver resolver;
    setUp(() => resolver = _seededResolver());

    test('firefox resolves to one canonical id across all formats', () {
      const expected = 'appstream:org.mozilla.firefox';
      final identities = [
        const AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        const AppIdentity(backendId: 'deb', nativeId: 'firefox'),
        const AppIdentity(
          backendId: 'flatpak',
          nativeId: 'org.mozilla.firefox',
        ),
        // Realistic version-pinned nativeIds (LLD §7): the lookup-key
        // normalization strips version/arch/repo.
        const AppIdentity(
          backendId: 'rpm',
          nativeId: 'firefox;136.0-1.fc42;x86_64;updates;installed',
        ),
        const AppIdentity(backendId: 'pacman', nativeId: 'firefox;146.0-1;;'),
      ];
      for (final id in identities) {
        expect(
          resolver.resolve(id)?.toString(),
          expected,
          reason: 'identity $id',
        );
      }
    });

    test('rpm lookup key strips version/arch/state', () {
      expect(
        resolver.resolve(
          const AppIdentity(
            backendId: 'rpm',
            nativeId: 'firefox;136.0-1.fc42;x86_64;updates;installed',
          ),
        ),
        equals(
          const CanonicalAppId(
            CanonicalIdScheme.appstream,
            'org.mozilla.firefox',
          ),
        ),
      );
    });

    test('unknown app resolves to null', () {
      expect(
        resolver.resolve(
          const AppIdentity(backendId: 'snap', nativeId: 'some-obscure-tool'),
        ),
        isNull,
      );
    });

    test('unknown backend id resolves to null and never throws', () {
      expect(
        resolver.resolve(
          const AppIdentity(backendId: 'no-such-backend', nativeId: 'firefox'),
        ),
        isNull,
      );
    });

    test('entryFor returns the curated entry', () {
      final entry = resolver.entryFor(
        const CanonicalAppId(
          CanonicalIdScheme.appstream,
          'org.mozilla.firefox',
        ),
      );
      expect(entry, isNotNull);
      expect(entry!.displayName, 'Firefox');
      expect(entry.backendKeys['snap'], contains('firefox'));
    });

    test('entryFor unknown id returns null', () {
      expect(
        resolver.entryFor(
          const CanonicalAppId(CanonicalIdScheme.appstream, 'org.example.Nope'),
        ),
        isNull,
      );
    });
  });

  group('signal-only resolution (fixture index)', () {
    // No backend keys at all: resolution must come from signals.
    late IdentityIndex index;
    setUp(() {
      index = IdentityIndex.fromJsonDocs([
        {
          'schemaVersion': 1,
          'entries': [
            {
              'canonicalId': 'appstream:org.example.SignalApp',
              'displayName': 'Signal App',
              'appstreamIds': ['org.example.SignalApp'],
              'homepages': ['example.com/signalapp'],
              'backends': <String, Object?>{},
              'provenance': {'source': 'test'},
            },
          ],
        },
      ]);
    });

    IdentityResolver resolver() => IdentityResolver(
      index: index,
      backends: {'snap': _FakeBackend('snap')},
    );

    test('appstream signal resolves without a backend key', () {
      expect(
        resolver()
            .resolve(
              const AppIdentity(
                backendId: 'snap',
                nativeId: 'unmapped-native-id',
              ),
              const IdentitySignal(appstreamId: 'org.example.SignalApp'),
            )
            ?.toString(),
        'appstream:org.example.SignalApp',
      );
    });

    test('homepage signal resolves with raw URL (scheme/www tolerated)', () {
      expect(
        resolver()
            .resolve(
              const AppIdentity(
                backendId: 'snap',
                nativeId: 'unmapped-native-id',
              ),
              const IdentitySignal(
                homepageUrl: 'https://www.example.com/signalapp/',
              ),
            )
            ?.toString(),
        'appstream:org.example.SignalApp',
      );
    });

    test('no signals and no backend key resolves to null', () {
      expect(
        resolver().resolve(
          const AppIdentity(backendId: 'snap', nativeId: 'unmapped-native-id'),
        ),
        isNull,
      );
    });
  });

  group('host gating', () {
    StoreHost hostWithFlag(bool enabled) {
      final flags = MapFeatureFlags();
      flags.setFlag('phase3.identity.enabled', enabled);
      return StoreHost(flags: flags);
    }

    test('flag off: host returns null without loading any index', () async {
      final host = hostWithFlag(false);
      host.registerBackend(_FakeBackend('snap'));
      expect(
        await host.resolveIdentity(
          const AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        ),
        isNull,
      );
    });

    test('flag off: unknown backend also returns null', () async {
      final host = hostWithFlag(false);
      expect(
        await host.resolveIdentity(
          const AppIdentity(backendId: 'nope', nativeId: 'firefox'),
        ),
        isNull,
      );
    });

    test('flag on: host resolves via the seeded index', () async {
      final host = hostWithFlag(true);
      host.registerBackend(_FakeBackend('snap'));
      host.registerBackend(_FakeBackend('deb'));
      host.registerBackend(_FakeBackend('flatpak'));
      host.registerBackend(_FakeBackend('rpm', keyFor: _rpmKey));
      host.registerBackend(_FakeBackend('pacman', keyFor: _pacmanKey));
      expect(
        (await host.resolveIdentity(
          const AppIdentity(backendId: 'deb', nativeId: 'firefox'),
        ))?.toString(),
        'appstream:org.mozilla.firefox',
      );
      expect(
        await host.resolveIdentity(
          const AppIdentity(backendId: 'deb', nativeId: 'some-obscure-tool'),
        ),
        isNull,
      );
    });
  });
}
