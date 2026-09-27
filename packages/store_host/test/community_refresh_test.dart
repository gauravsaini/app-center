/// Tests for the community index refresh + reload API
/// (docs/architecture/phase3-slice3.md §5, §6, §9).
///
/// The transport seam is faked (scripted bodies/throws); fixture docs
/// are signed with ephemeral Ed25519 keypairs generated in-test — the
/// placeholder bootstrap key is never used. Each test gets an
/// isolated fake HOME. Leaf A's crypto internals are NOT retested
/// here (community_crypto_test.dart covers them); what IS tested is
/// the integration: fetch → verify → atomic write → reload.
/// Test-only doubles; never touch the live system.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:store_host/src/identity/community_crypto.dart';
import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

const _m1 = 'https://m1.example/index.json';
const _m2 = 'https://m2.example/index.json';

/// Scripted [CommunityIndexTransport]: [script] maps a mirror URL
/// string to either the body to return or the exception to throw.
class FakeCommunityTransport implements CommunityIndexTransport {
  FakeCommunityTransport(this.script);

  final Map<String, Object> script;
  final List<String> fetched = [];

  @override
  Future<String> fetch(Uri url) async {
    fetched.add(url.toString());
    final scripted = script[url.toString()];
    if (scripted is String) return scripted;
    if (scripted is Exception) throw scripted;
    throw CommunityFetchException('no scripted response for $url');
  }
}

/// Minimal backend stub with a configurable id. Never touches the
/// live system.
class StubCommunityBackend extends StoreBackend {
  StubCommunityBackend(this.backendId);

  final String backendId;

  @override
  String get id => backendId;

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {};

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => const Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> install(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> remove(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> update(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<List<UpdateInfo>> checkUpdates() async => const [];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}

/// Ephemeral Ed25519 keypair + a trust store pinning it — the
/// placeholder bootstrap key is never used.
Future<({CommunityTrustStore trust, SimpleKeyPair keyPair, String keyId})>
_ephemeralTrust({String keyId = 'test-key'}) async {
  final keyPair = await Ed25519().newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return (
    trust: CommunityTrustStore({keyId: base64.encode(publicKey.bytes)}),
    keyPair: keyPair,
    keyId: keyId,
  );
}

/// Signs [doc] (minus any existing `signature`) with [keyPair] under
/// [keyId] and returns the JSON body the mirror would serve.
Future<String> _signedBody(
  Map<String, Object?> doc, {
  required SimpleKeyPair keyPair,
  required String keyId,
}) async {
  final body = Map<String, Object?>.of(doc)..remove('signature');
  final message = canonicalJsonBytes(body);
  final signature = await Ed25519().sign(message, keyPair: keyPair);
  body['signature'] = <String, Object?>{
    'keyId': keyId,
    'algorithm': 'ed25519',
    'sig': base64.encode(signature.bytes),
  };
  return jsonEncode(body);
}

/// One community index entry mapping [backendId]/[lookupKey] to
/// [canonicalId].
Map<String, Object?> _entry({
  required String canonicalId,
  required String backendId,
  required String lookupKey,
  String displayName = 'Test App',
}) => {
  'canonicalId': canonicalId,
  'displayName': displayName,
  'appstreamIds': <String>[],
  'homepages': <String>[],
  'backends': {
    backendId: [lookupKey],
  },
  'provenance': {'source': 'community'},
};

/// A community index doc (envelope added by [_signedBody]).
Map<String, Object?> _communityDoc(
  List<Map<String, Object?>> entries, {
  String generatedAt = '2026-09-28T00:00:00Z',
}) => {
  'schemaVersion': 1,
  'generatedAt': generatedAt,
  'source': 'community',
  'entries': entries,
  'aliases': <String, Object?>{},
};

/// Local overlay doc: the shape FileIdentityIndexStore.saveOverlay
/// writes.
String _overlayDoc(List<Map<String, Object?>> entries) =>
    jsonEncode({'schemaVersion': 1, 'source': 'local', 'entries': entries});

/// Builds a host with identity + community enabled and the given
/// mirrors, rooted at a fake HOME. The environment is injected so no
/// test ever touches the real `~/.local/share/libreapp-center/`.
StoreHost _makeHost({
  required Directory home,
  Map<String, Object>? flags,
  Map<String, String>? environment,
  List<String> backendIds = const ['communitytest'],
}) {
  final host = StoreHost(
    flags: MapFeatureFlags({
      'phase3.identity.enabled': true,
      'phase3.community.enabled': true,
      'phase3.community.mirrors': '$_m1,$_m2',
      ...?flags,
    }),
    environment: environment ?? {'HOME': home.path},
  );
  for (final id in backendIds) {
    host.registerBackend(StubCommunityBackend(id));
  }
  return host;
}

String _communityPath(Directory home) =>
    '${home.path}/.local/share/libreapp-center/identity-community.json';

String _overlayPath(Directory home) =>
    '${home.path}/.local/share/libreapp-center/identity-overlay.json';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('community-refresh-test');
  });

  tearDown(() async {
    await home.delete(recursive: true);
  });

  group('gating', () {
    test('community flag off → skipped, no fetch attempted', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeCommunityTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.community.enabled': false},
      );
      final result = await host.refreshCommunityIndex(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('phase3.community.enabled'));
      expect(transport.fetched, isEmpty);
    });

    test('identity flag off → skipped, no fetch attempted', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeCommunityTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.identity.enabled': false},
      );
      final result = await host.refreshCommunityIndex(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('phase3.identity.enabled'));
      expect(transport.fetched, isEmpty);
    });

    test('mirrors empty → skipped', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeCommunityTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.community.mirrors': ''},
      );
      final result = await host.refreshCommunityIndex(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('mirrors'));
      expect(transport.fetched, isEmpty);
    });

    test('HOME absent → skipped', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeCommunityTransport(const {});
      final host = _makeHost(home: home, environment: const {});
      final result = await host.refreshCommunityIndex(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('HOME'));
      expect(transport.fetched, isEmpty);
    });
  });

  group('mirror failover + verify-write-reload', () {
    test('first mirror throws, second verifies → ok; file written; '
        'resolver picks up the new layer', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _communityDoc([
          _entry(
            canonicalId: 'appstream:org.example.CommunityApp',
            backendId: 'communitytest',
            lookupKey: 'community-app',
          ),
        ]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final transport = FakeCommunityTransport({
        _m1: const CommunityFetchException('connection refused'),
        _m2: body,
      });
      final host = _makeHost(home: home);
      const id = AppIdentity(
        backendId: 'communitytest',
        nativeId: 'community-app',
      );

      // Before the refresh only the seed exists: unresolved.
      expect(await host.resolveIdentity(id), isNull);

      final result = await host.refreshCommunityIndex(
        transport: transport,
        trust: trust,
      );
      expect(result.isOk, isTrue);
      expect(result.entryCount, 1);
      expect(result.generatedAt, DateTime.utc(2026, 9, 28));
      expect(result.mirror, _m2);

      // The verified doc was written to the community layer file.
      final file = File(_communityPath(home));
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), body);

      // The resolver picks up the new layer — no host restart.
      expect(
        await host.resolveIdentity(id),
        equals(
          const CanonicalAppId(
            CanonicalIdScheme.appstream,
            'org.example.CommunityApp',
          ),
        ),
      );
    });

    test('entryCount reflects the verified doc', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _communityDoc([
          for (var i = 0; i < 3; i++)
            _entry(
              canonicalId: 'appstream:org.example.App$i',
              backendId: 'communitytest',
              lookupKey: 'app-$i',
            ),
        ]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      final result = await host.refreshCommunityIndex(
        transport: FakeCommunityTransport({_m1: body, _m2: body}),
        trust: trust,
      );
      expect(result.isOk, isTrue);
      expect(result.entryCount, 3);
    });
  });

  group('failure handling', () {
    test('tampered doc on all mirrors → failed; previous community '
        'file untouched; in-memory index unchanged', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final entry = _entry(
        canonicalId: 'appstream:org.example.CommunityApp',
        backendId: 'communitytest',
        lookupKey: 'community-app',
      );
      final body = await _signedBody(
        _communityDoc([entry]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      const id = AppIdentity(
        backendId: 'communitytest',
        nativeId: 'community-app',
      );
      const canonical = CanonicalAppId(
        CanonicalIdScheme.appstream,
        'org.example.CommunityApp',
      );

      // Establish a good community layer first.
      final good = await host.refreshCommunityIndex(
        transport: FakeCommunityTransport({_m1: body, _m2: body}),
        trust: trust,
      );
      expect(good.isOk, isTrue);
      final file = File(_communityPath(home));
      final before = await file.readAsString();
      expect(await host.resolveIdentity(id), equals(canonical));

      // Tamper AFTER signing: change a byte the signature covers.
      final tamperedDoc = (jsonDecode(body) as Map<String, Object?>);
      final entries = tamperedDoc['entries'] as List;
      (entries.first as Map<String, Object?>)['displayName'] = 'Evil Twin';
      final tamperedBody = jsonEncode(tamperedDoc);

      final result = await host.refreshCommunityIndex(
        transport: FakeCommunityTransport({
          _m1: tamperedBody,
          _m2: tamperedBody,
        }),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
      expect(result.errorsByMirror.keys, containsAll([_m1, _m2]));
      expect(
        result.errorsByMirror.values.first,
        contains('signature rejected'),
      );

      // Previous community file untouched (verify-before-write).
      expect(await file.readAsString(), before);
      // In-memory index unchanged.
      expect(await host.resolveIdentity(id), equals(canonical));
    });

    test('unsigned doc on all mirrors → failed; never merged', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      // A well-formed doc with the envelope stripped: rejected like a
      // corrupt doc, never merged.
      final body = await _signedBody(
        _communityDoc([
          _entry(
            canonicalId: 'appstream:org.example.CommunityApp',
            backendId: 'communitytest',
            lookupKey: 'community-app',
          ),
        ]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final unsignedDoc = Map<String, Object?>.of(
        jsonDecode(body) as Map<String, Object?>,
      )..remove('signature');
      final unsignedBody = jsonEncode(unsignedDoc);

      final host = _makeHost(home: home);
      final result = await host.refreshCommunityIndex(
        transport: FakeCommunityTransport({
          _m1: unsignedBody,
          _m2: unsignedBody,
        }),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
      expect(result.errorsByMirror.keys, containsAll([_m1, _m2]));
      expect(
        result.errorsByMirror.values.first,
        contains('signature rejected'),
      );
      // Nothing was ever written.
      expect(await File(_communityPath(home)).exists(), isFalse);
    });

    test('non-https mirror skipped; https mirror still wins', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _communityDoc([
          _entry(
            canonicalId: 'appstream:org.example.CommunityApp',
            backendId: 'communitytest',
            lookupKey: 'community-app',
          ),
        ]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final transport = FakeCommunityTransport({_m2: body});
      final host = _makeHost(
        home: home,
        flags: {'phase3.community.mirrors': 'http://m1.example/x.json,$_m2'},
      );
      final result = await host.refreshCommunityIndex(
        transport: transport,
        trust: trust,
      );
      expect(result.isOk, isTrue);
      expect(result.mirror, _m2);
      // The http mirror never reached the transport.
      expect(transport.fetched, [_m2]);
    });

    test(
      'all mirrors non-https → failed with per-mirror diagnostics',
      () async {
        final trust = await _ephemeralTrust();
        final transport = FakeCommunityTransport(const {});
        final host = _makeHost(
          home: home,
          flags: {'phase3.community.mirrors': 'http://m1.example/x.json'},
        );
        final result = await host.refreshCommunityIndex(
          transport: transport,
          trust: trust.trust,
        );
        expect(result.isFailed, isTrue);
        expect(
          result.errorsByMirror['http://m1.example/x.json'],
          contains('https'),
        );
        expect(transport.fetched, isEmpty);
      },
    );

    test('offline: all mirrors throw → failed, stale index intact, '
        'no throw', () async {
      final trust = await _ephemeralTrust();
      final host = _makeHost(home: home, backendIds: ['snap']);
      // Seed-only resolution works before the refresh.
      const firefox = AppIdentity(backendId: 'snap', nativeId: 'firefox');
      const seedCanonical = CanonicalAppId(
        CanonicalIdScheme.appstream,
        'org.mozilla.firefox',
      );
      expect(await host.resolveIdentity(firefox), equals(seedCanonical));

      // The refresh itself must not throw — "all mirrors down" is a
      // result, not an exception.
      final result = await host.refreshCommunityIndex(
        transport: FakeCommunityTransport({
          _m1: const CommunityFetchException('network unreachable'),
          _m2: const CommunityFetchException('network unreachable'),
        }),
        trust: trust.trust,
      );
      expect(result.isFailed, isTrue);
      expect(result.errorsByMirror.keys, containsAll([_m1, _m2]));

      // Stale index intact.
      expect(await host.resolveIdentity(firefox), equals(seedCanonical));
    });
  });

  group('layer order', () {
    test('seed < community < local overlay', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      // The community doc re-maps BOTH a seed entry and a key the
      // local overlay also claims.
      final body = await _signedBody(
        _communityDoc([
          // Community outranks the seed: the seed maps snap/firefox
          // to appstream:org.mozilla.firefox.
          _entry(
            canonicalId: 'appstream:org.example.CommunityFirefox',
            backendId: 'snap',
            lookupKey: 'firefox',
            displayName: 'Community Firefox',
          ),
          // The local overlay (written below) claims this same key:
          // the overlay must win on conflict.
          _entry(
            canonicalId: 'appstream:org.example.CommunityA',
            backendId: 'communitytest',
            lookupKey: 'conflict-app',
            displayName: 'Community A',
          ),
        ]),
        keyPair: keyPair,
        keyId: keyId,
      );
      // The user's own overlay outranks community.
      await File(_overlayPath(home)).parent.create(recursive: true);
      await File(_overlayPath(home)).writeAsString(
        _overlayDoc([
          _entry(
            canonicalId: 'appstream:org.example.OverlayB',
            backendId: 'communitytest',
            lookupKey: 'conflict-app',
            displayName: 'Overlay B',
          ),
        ]),
      );

      final host = _makeHost(home: home, backendIds: ['snap', 'communitytest']);
      final result = await host.refreshCommunityIndex(
        transport: FakeCommunityTransport({_m1: body, _m2: body}),
        trust: trust,
      );
      expect(result.isOk, isTrue);

      // Community wins over the seed.
      expect(
        await host.resolveIdentity(
          const AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        ),
        equals(
          const CanonicalAppId(
            CanonicalIdScheme.appstream,
            'org.example.CommunityFirefox',
          ),
        ),
      );
      // The local overlay wins over community on conflict.
      expect(
        await host.resolveIdentity(
          const AppIdentity(
            backendId: 'communitytest',
            nativeId: 'conflict-app',
          ),
        ),
        equals(
          const CanonicalAppId(
            CanonicalIdScheme.appstream,
            'org.example.OverlayB',
          ),
        ),
      );
    });
  });

  group('reloadIdentityIndex', () {
    test('reload before first load is a no-op, never throws', () {
      final host = _makeHost(home: home);
      host.reloadIdentityIndex();
    });

    test('hand-written overlay → reload → resolution reflects it; '
        'no restart', () async {
      final host = _makeHost(home: home);
      const id = AppIdentity(
        backendId: 'communitytest',
        nativeId: 'handwritten-app',
      );
      const canonical = CanonicalAppId(
        CanonicalIdScheme.appstream,
        'org.example.Handwritten',
      );
      expect(await host.resolveIdentity(id), isNull);

      // Fix the overlay by hand on disk.
      await File(_overlayPath(home)).parent.create(recursive: true);
      await File(_overlayPath(home)).writeAsString(
        _overlayDoc([
          _entry(
            canonicalId: 'appstream:org.example.Handwritten',
            backendId: 'communitytest',
            lookupKey: 'handwritten-app',
          ),
        ]),
      );

      // Cached index still says unresolved…
      expect(await host.resolveIdentity(id), isNull);

      // …until the reload drops the cache.
      host.reloadIdentityIndex();
      expect(await host.resolveIdentity(id), equals(canonical));
    });
  });
}
