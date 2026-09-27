/// Tests for the community metadata fetch/verify/lookup
/// (docs/architecture/phase3-slice5.md §7).
///
/// The transport seam is faked (scripted bodies/throws); fixture docs
/// are signed with ephemeral Ed25519 keypairs generated in-test — the
/// placeholder bootstrap key is never used. Each test gets an
/// isolated fake HOME. The slice-3 crypto internals are NOT retested
/// here (community_crypto_test.dart covers them); what IS tested is
/// the new surface: `expectedDocType`, record/block forgiveness,
/// permission invariants, store alias-follow, and the host refresh /
/// lookup / reload API.
/// Test-only doubles; never touch the live system.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:store_host/src/identity/community_crypto.dart';
import 'package:store_host/src/identity/community_metadata.dart';
import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

const _m1 = 'https://m1.example/metadata.json';
const _m2 = 'https://m2.example/metadata.json';

/// Scripted [CommunityIndexTransport]: [script] maps a mirror URL
/// string to either the body to return or the exception to throw.
class FakeMetadataTransport implements CommunityIndexTransport {
  FakeMetadataTransport(this.script);

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
class StubMetadataBackend extends StoreBackend {
  StubMetadataBackend(this.backendId);

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

/// One community metadata record. Keys are included only when
/// non-null so tests can assert on absent fields too.
Map<String, Object?> _record({
  String canonicalId = 'appstream:org.example.App',
  String? summary = 'A test app',
  String? description = 'A longer, curator-written description.',
  List<Map<String, Object?>>? screenshots,
  Map<String, Object?>? permissions,
  Map<String, Object?>? rating,
  bool includeUnknownFields = false,
}) => {
  'canonicalId': canonicalId,
  if (summary != null) 'summary': summary,
  if (description != null) 'description': description,
  if (screenshots != null) 'screenshots': screenshots,
  if (permissions != null) 'permissions': permissions,
  if (rating != null) 'rating': rating,
  if (includeUnknownFields) 'futureField': 'ignored for forward compat',
};

Map<String, Object?> _screenshot(String url, {String? caption}) => {
  'url': url,
  if (caption != null) 'caption': caption,
};

Map<String, Object?> _permissions({
  String sandboxing = 'sandboxed',
  List<String>? capabilities,
  String? source = 'curated-review',
}) => {
  'sandboxing': sandboxing,
  if (capabilities != null) 'capabilities': capabilities,
  if (source != null) 'source': source,
};

/// A community metadata doc (envelope added by [_signedBody]).
/// [docType] null → the key is omitted entirely (identity-doc shape).
Map<String, Object?> _metadataDoc(
  List<Object?> records, {
  String generatedAt = '2026-09-28T02:30:00Z',
  String? docType = 'community-metadata',
  int? schemaVersion = 1,
}) => {
  if (schemaVersion != null) 'schemaVersion': schemaVersion,
  if (docType != null) 'docType': docType,
  'generatedAt': generatedAt,
  'source': 'community',
  'metadata': records,
};

/// Builds a host with identity + metadata + community enabled and the
/// given mirrors, rooted at a fake HOME. The environment is injected
/// so no test ever touches the real `~/.local/share/libreapp-center/`.
StoreHost _makeHost({
  required Directory home,
  Map<String, Object>? flags,
  Map<String, String>? environment,
  List<String> backendIds = const ['metadatatest'],
}) {
  final host = StoreHost(
    flags: MapFeatureFlags({
      'phase3.identity.enabled': true,
      'phase3.metadata.enabled': true,
      'phase3.community.enabled': true,
      'phase3.community.metadata.mirrors': '$_m1,$_m2',
      ...?flags,
    }),
    environment: environment ?? {'HOME': home.path},
  );
  for (final id in backendIds) {
    host.registerBackend(StubMetadataBackend(id));
  }
  return host;
}

String _metadataPath(Directory home) =>
    '${home.path}/.local/share/libreapp-center/identity-metadata.json';

String _overlayPath(Directory home) =>
    '${home.path}/.local/share/libreapp-center/identity-overlay.json';

const _appId = CanonicalAppId(CanonicalIdScheme.appstream, 'org.example.App');

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('community-metadata-test');
  });

  tearDown(() async {
    await home.delete(recursive: true);
  });

  group('verifyCommunityDoc expectedDocType', () {
    test('correct docType verifies', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final verified = await verifyCommunityDoc(
        jsonDecode(body) as Map<String, Object?>,
        trust,
        expectedDocType: 'community-metadata',
      );
      expect(verified.keyId, keyId);
      expect(verified.doc['docType'], 'community-metadata');
      expect(verified.doc.containsKey('signature'), isFalse);
    });

    test('identity doc (no docType) on the metadata path → rejected', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()], docType: null),
        keyPair: keyPair,
        keyId: keyId,
      );
      expect(
        verifyCommunityDoc(
          jsonDecode(body) as Map<String, Object?>,
          trust,
          expectedDocType: 'community-metadata',
        ),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('cross-served'),
          ),
        ),
      );
    });

    test('wrong docType → rejected', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()], docType: 'community-index'),
        keyPair: keyPair,
        keyId: keyId,
      );
      expect(
        verifyCommunityDoc(
          jsonDecode(body) as Map<String, Object?>,
          trust,
          expectedDocType: 'community-metadata',
        ),
        throwsA(isA<CommunitySignatureException>()),
      );
    });

    test('null expectedDocType preserves slice-3 behavior '
        '(no docType check)', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()], docType: null),
        keyPair: keyPair,
        keyId: keyId,
      );
      final verified = await verifyCommunityDoc(
        jsonDecode(body) as Map<String, Object?>,
        trust,
      );
      expect(verified.keyId, keyId);
    });

    test('tampered metadata byte → reject', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final tampered = Map<String, Object?>.of(
        jsonDecode(body) as Map<String, Object?>,
      );
      (tampered['metadata'] as List).add(_record());
      expect(
        verifyCommunityDoc(
          tampered,
          trust,
          expectedDocType: 'community-metadata',
        ),
        throwsA(isA<CommunitySignatureException>()),
      );
    });

    test('unsigned metadata doc → reject', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final unsigned = Map<String, Object?>.of(
        jsonDecode(body) as Map<String, Object?>,
      )..remove('signature');
      expect(
        verifyCommunityDoc(
          unsigned,
          trust,
          expectedDocType: 'community-metadata',
        ),
        throwsA(isA<CommunitySignatureException>()),
      );
    });

    test('wrong key → reject', () async {
      final ephemeral = await _ephemeralTrust();
      final other = await _ephemeralTrust(keyId: 'other-key');
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: ephemeral.keyPair,
        keyId: ephemeral.keyId,
      );
      expect(
        verifyCommunityDoc(
          jsonDecode(body) as Map<String, Object?>,
          other.trust,
          expectedDocType: 'community-metadata',
        ),
        throwsA(isA<CommunitySignatureException>()),
      );
    });
  });

  group('CommunityAppMetadata.fromJson', () {
    test('full record parses', () {
      final record = CommunityAppMetadata.fromJson(
        _record(
          screenshots: [
            _screenshot('https://cdn.example/a.png', caption: 'Start'),
            _screenshot('https://cdn.example/b.png'),
          ],
          permissions: _permissions(
            capabilities: ['network', 'audio.playback'],
          ),
          rating: {'mean': 4.3, 'count': 128},
          includeUnknownFields: true,
        ),
      );
      expect(record.canonicalId, _appId);
      expect(record.summary, 'A test app');
      expect(record.description, contains('curator-written'));
      expect(record.screenshots, hasLength(2));
      expect(record.screenshots.first.url, 'https://cdn.example/a.png');
      expect(record.screenshots.first.caption, 'Start');
      expect(record.screenshots.last.caption, isNull);
      expect(record.permissions!.sandboxing, CommunitySandboxing.sandboxed);
      expect(record.permissions!.capabilities, ['network', 'audio.playback']);
      expect(record.permissions!.source, 'curated-review');
      expect(record.rating!.mean, 4.3);
      expect(record.rating!.count, 128);
      expect(record.provenance.source, 'community');
    });

    test('minimal record: absent fields stay null', () {
      final record = CommunityAppMetadata.fromJson({
        'canonicalId': 'appstream:org.example.App',
      });
      expect(record.summary, isNull);
      expect(record.description, isNull);
      expect(record.screenshots, isEmpty);
      expect(record.permissions, isNull);
      expect(record.rating, isNull);
    });

    test('bad canonicalId → throws (load layer skips the record)', () {
      expect(
        () => CommunityAppMetadata.fromJson(_record(canonicalId: 'name:foo')),
        throwsFormatException,
      );
      expect(
        () => CommunityAppMetadata.fromJson(_record(canonicalId: 'not-an-id')),
        throwsFormatException,
      );
    });

    test('empty summary/description = absent', () {
      final record = CommunityAppMetadata.fromJson(
        _record(summary: '', description: ''),
      );
      expect(record.summary, isNull);
      expect(record.description, isNull);
    });

    test('non-https screenshot → that screenshot dropped, record kept', () {
      final record = CommunityAppMetadata.fromJson(
        _record(
          screenshots: [
            _screenshot('http://cdn.example/plain.png'),
            _screenshot('https://cdn.example/ok.png'),
            _screenshot('ftp://cdn.example/x.png'),
          ],
        ),
      );
      expect(record.screenshots, hasLength(1));
      expect(record.screenshots.single.url, 'https://cdn.example/ok.png');
    });

    test('rating without count → rating null, record kept', () {
      final record = CommunityAppMetadata.fromJson(
        _record(rating: {'mean': 4.3}),
      );
      expect(record.rating, isNull);
      expect(record.canonicalId, _appId);
    });

    test('mean outside 0–5 or count < 1 → rating null', () {
      for (final rating in [
        {'mean': 5.5, 'count': 10},
        {'mean': -0.1, 'count': 10},
        {'mean': 4.0, 'count': 0},
        {'mean': 4.0, 'count': -3},
        {'mean': 'high', 'count': 10},
      ]) {
        final record = CommunityAppMetadata.fromJson(_record(rating: rating));
        expect(record.rating, isNull, reason: 'rating: $rating');
      }
    });

    test('non-map rating → rating null, record kept', () {
      final record = CommunityAppMetadata.fromJson(
        _record()..['rating'] = 'not-a-map',
      );
      expect(record.rating, isNull);
      expect(record.canonicalId, _appId);
    });

    test('int mean parses', () {
      final record = CommunityAppMetadata.fromJson(
        _record(rating: {'mean': 4, 'count': 7}),
      );
      expect(record.rating!.mean, 4.0);
      expect(record.rating!.count, 7);
    });

    test('unknown capability → block dropped, record kept', () {
      final record = CommunityAppMetadata.fromJson(
        _record(permissions: _permissions(capabilities: ['telepathy'])),
      );
      expect(record.permissions, isNull);
      expect(record.canonicalId, _appId);
    });

    test('unsandboxed + anything-but-[full-system-trust] → block dropped', () {
      for (final caps in [
        ['network'],
        ['full-system-trust', 'network'],
        <String>[],
      ]) {
        final record = CommunityAppMetadata.fromJson(
          _record(
            permissions: _permissions(
              sandboxing: 'unsandboxed',
              capabilities: caps,
            ),
          ),
        );
        expect(record.permissions, isNull, reason: 'caps: $caps');
      }
    });

    test('unsandboxed + [full-system-trust] alone → valid', () {
      final record = CommunityAppMetadata.fromJson(
        _record(
          permissions: _permissions(
            sandboxing: 'unsandboxed',
            capabilities: ['full-system-trust'],
            source: 'upstream-manifest',
          ),
        ),
      );
      expect(record.permissions!.sandboxing, CommunitySandboxing.unsandboxed);
      expect(record.permissions!.capabilities, ['full-system-trust']);
    });

    test('sandboxed + full-system-trust → block dropped', () {
      final record = CommunityAppMetadata.fromJson(
        _record(permissions: _permissions(capabilities: ['full-system-trust'])),
      );
      expect(record.permissions, isNull);
    });

    test('unknown sandboxing + empty capabilities → absent block', () {
      final record = CommunityAppMetadata.fromJson(
        _record(permissions: _permissions(sandboxing: 'unknown')),
      );
      expect(record.permissions, isNull);
    });

    test('unknown sandboxing value → block dropped', () {
      final record = CommunityAppMetadata.fromJson(
        _record(
          permissions: _permissions(
            sandboxing: 'maybe',
            capabilities: ['network'],
          ),
        ),
      );
      expect(record.permissions, isNull);
    });
  });

  group('CommunityPermissions.fromJson invariants', () {
    test('valid sandboxed block parses', () {
      final p = CommunityPermissions.fromJson(
        _permissions(capabilities: ['network', 'home.read']),
      );
      expect(p.sandboxing, CommunitySandboxing.sandboxed);
      expect(p.capabilities, ['network', 'home.read']);
    });

    test('violations throw FormatException', () {
      // unsandboxed with finer capabilities
      expect(
        () => CommunityPermissions.fromJson(
          _permissions(sandboxing: 'unsandboxed', capabilities: ['network']),
        ),
        throwsFormatException,
      );
      // atomic full-system-trust paired with another capability
      expect(
        () => CommunityPermissions.fromJson(
          _permissions(
            sandboxing: 'unknown',
            capabilities: ['full-system-trust', 'network'],
          ),
        ),
        throwsFormatException,
      );
      // sandboxed forbids full-system-trust
      expect(
        () => CommunityPermissions.fromJson(
          _permissions(capabilities: ['full-system-trust']),
        ),
        throwsFormatException,
      );
      // unknown capability id
      expect(
        () => CommunityPermissions.fromJson(
          _permissions(capabilities: ['network', 'mind-reading']),
        ),
        throwsFormatException,
      );
      // unknown source
      expect(
        () => CommunityPermissions.fromJson(
          _permissions(capabilities: ['network'], source: 'word-of-mouth'),
        ),
        throwsFormatException,
      );
    });
  });

  group('CommunityMetadataStore.load', () {
    test('never throws: missing file → empty', () async {
      final store = CommunityMetadataStore();
      await store.load(paths: [_metadataPath(home)]);
      expect(store.entryFor(_appId, IdentityIndex.empty()), isNull);
      expect(store.skippedRecords, 0);
    });

    test('never throws: corrupt JSON → empty', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString('{not json');
      final store = CommunityMetadataStore();
      await store.load(paths: [_metadataPath(home)]);
      expect(store.entryFor(_appId, IdentityIndex.empty()), isNull);
    });

    test('bad record skipped + counted; good records merge', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(
          _metadataDoc([
            _record(),
            _record(canonicalId: 'name:bad-scheme'),
            'not-a-record',
            _record(
              canonicalId: 'appstream:org.example.Second',
              summary: 'Second app',
            ),
          ]),
        ),
      );
      final store = CommunityMetadataStore();
      await store.load(paths: [_metadataPath(home)]);
      expect(store.skippedRecords, 2);
      expect(
        store.entryFor(_appId, IdentityIndex.empty())!.summary,
        'A test app',
      );
      expect(
        store
            .entryFor(
              const CanonicalAppId(
                CanonicalIdScheme.appstream,
                'org.example.Second',
              ),
              IdentityIndex.empty(),
            )!
            .summary,
        'Second app',
      );
    });

    test('non-1 schemaVersion doc → skipped wholesale', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(_metadataDoc([_record()], schemaVersion: 2)),
      );
      final store = CommunityMetadataStore();
      await store.load(paths: [_metadataPath(home)]);
      expect(store.entryFor(_appId, IdentityIndex.empty()), isNull);
    });

    test('alias-follow: metadata keyed by retired homepage: id is found '
        'after the identity index promotes it to appstream:', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(
          _metadataDoc([
            _record(
              canonicalId: 'homepage:example.org/oldapp',
              summary: 'Old homepage id',
            ),
          ]),
        ),
      );
      // Identity index: the entry now lives at appstream:, with the
      // old homepage: id as an alias.
      final index = IdentityIndex.fromJsonDocs([
        {
          'schemaVersion': 1,
          'entries': [
            {
              'canonicalId': 'appstream:org.example.OldApp',
              'displayName': 'Old App',
              'appstreamIds': <String>[],
              'homepages': <String>[],
              'backends': <String, Object?>{},
              'provenance': {'source': 'local'},
            },
          ],
          'aliases': {
            'homepage:example.org/oldapp': 'appstream:org.example.OldApp',
          },
        },
      ]);
      final store = CommunityMetadataStore();
      await store.load(paths: [_metadataPath(home)]);
      const promoted = CanonicalAppId(
        CanonicalIdScheme.appstream,
        'org.example.OldApp',
      );
      // Queried by the PROMOTED id: found via the alias chain.
      expect(store.entryFor(promoted, index)!.summary, 'Old homepage id');
      // Queried by the retired id directly: also found.
      expect(
        store
            .entryFor(
              const CanonicalAppId(
                CanonicalIdScheme.homepage,
                'example.org/oldapp',
              ),
              index,
            )!
            .summary,
        'Old homepage id',
      );
    });
  });

  group('refreshCommunityMetadata gating', () {
    test('identity flag off → skipped, no fetch attempted', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeMetadataTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.identity.enabled': false},
      );
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('phase3.identity.enabled'));
      expect(transport.fetched, isEmpty);
    });

    test('metadata flag off → skipped, no fetch attempted', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeMetadataTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.metadata.enabled': false},
      );
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('phase3.metadata.enabled'));
      expect(transport.fetched, isEmpty);
    });

    test('community flag off → skipped', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeMetadataTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.community.enabled': false},
      );
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('phase3.community.enabled'));
      expect(transport.fetched, isEmpty);
    });

    test('mirrors empty → skipped', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeMetadataTransport(const {});
      final host = _makeHost(
        home: home,
        flags: {'phase3.community.metadata.mirrors': ''},
      );
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('mirrors'));
      expect(transport.fetched, isEmpty);
    });

    test('HOME absent → skipped', () async {
      final trust = await _ephemeralTrust();
      final transport = FakeMetadataTransport(const {});
      final host = _makeHost(home: home, environment: const {});
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust.trust,
      );
      expect(result.isSkipped, isTrue);
      expect(result.reason, contains('HOME'));
      expect(transport.fetched, isEmpty);
    });
  });

  group('refreshCommunityMetadata fetch → verify → write → reload', () {
    test('happy path: ok, atomic write, reload, keyId carried', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([
          _record(),
          _record(canonicalId: 'appstream:org.example.B'),
        ]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final transport = FakeMetadataTransport({_m1: body, _m2: body});
      final host = _makeHost(home: home);

      expect(await host.getCommunityMetadata(_appId), isNull);

      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust,
      );
      expect(result.isOk, isTrue);
      expect(result.entryCount, 2);
      expect(result.generatedAt, DateTime.utc(2026, 9, 28, 2, 30));
      expect(result.mirror, _m1);
      expect(result.keyId, keyId);

      // Atomic temp+rename: the verified body is the file, no .tmp left.
      final file = File(_metadataPath(home));
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), body);
      expect(await File('${_metadataPath(home)}.tmp').exists(), isFalse);

      // The in-memory cache reloaded — no host restart.
      expect(
        (await host.getCommunityMetadata(_appId))!.description,
        contains('curator-written'),
      );
    });

    test('identity doc cross-served on the metadata path → failed; '
        'nothing written', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      // Signed but WITHOUT docType: the identity doc shape.
      final body = await _signedBody(
        _metadataDoc([_record()], docType: null),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      final result = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({_m1: body, _m2: body}),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
      expect(result.errorsByMirror[_m1], contains('cross-served'));
      expect(result.errorsByMirror[_m2], contains('cross-served'));
      expect(await File(_metadataPath(home)).exists(), isFalse);
      expect(await host.getCommunityMetadata(_appId), isNull);
    });

    test('wrong docType → failed', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()], docType: 'community-index'),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      final result = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({_m1: body}),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
    });

    test('tampered doc → failed; previous file + cache untouched', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      final good = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({_m1: body, _m2: body}),
        trust: trust,
      );
      expect(good.isOk, isTrue);
      final file = File(_metadataPath(home));
      final before = await file.readAsString();
      expect((await host.getCommunityMetadata(_appId))!.summary, 'A test app');

      // Tamper AFTER signing: change a byte the signature covers.
      final tamperedDoc = jsonDecode(body) as Map<String, Object?>;
      ((tamperedDoc['metadata'] as List).first
              as Map<String, Object?>)['summary'] =
          'Evil Twin';
      final tamperedBody = jsonEncode(tamperedDoc);

      final result = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({
          _m1: tamperedBody,
          _m2: tamperedBody,
        }),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
      expect(
        result.errorsByMirror.values.first,
        contains('signature rejected'),
      );

      // Previous file untouched (verify-before-write) and the stale
      // cache intact.
      expect(await file.readAsString(), before);
      expect((await host.getCommunityMetadata(_appId))!.summary, 'A test app');
    });

    test('unsigned doc → failed; never written', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final unsigned = Map<String, Object?>.of(
        jsonDecode(body) as Map<String, Object?>,
      )..remove('signature');
      final host = _makeHost(home: home);
      final result = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({
          _m1: jsonEncode(unsigned),
          _m2: jsonEncode(unsigned),
        }),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
      expect(await File(_metadataPath(home)).exists(), isFalse);
    });

    test('wrong key → failed', () async {
      final ephemeral = await _ephemeralTrust();
      final other = await _ephemeralTrust(keyId: 'other-key');
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: ephemeral.keyPair,
        keyId: ephemeral.keyId,
      );
      final host = _makeHost(home: home);
      final result = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({_m1: body}),
        trust: other.trust,
      );
      expect(result.isFailed, isTrue);
      expect(await File(_metadataPath(home)).exists(), isFalse);
    });

    test('body > 10 MiB → rejected before parse; next mirror wins', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final bigDoc = _metadataDoc([
        _record(description: 'x' * (11 * 1024 * 1024)),
      ]);
      final bigBody = await _signedBody(bigDoc, keyPair: keyPair, keyId: keyId);
      // Sanity: the fixture really is over the cap.
      expect(bigBody.length, greaterThan(10 * 1024 * 1024));
      final goodBody = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      final transport = FakeMetadataTransport({_m1: bigBody, _m2: goodBody});
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust,
      );
      expect(result.isOk, isTrue);
      expect(result.mirror, _m2);
      // m1's doc was correctly signed — the ONLY reason it lost is the
      // pre-parse size cap (errorsByMirror is empty on ok by design,
      // same as the slice-3 result shape).
      expect(transport.fetched, contains(_m1));
      expect(result.entryCount, 1);
    });

    test('offline: all mirrors throw → failed, stale cache intact, '
        'no throw', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final host = _makeHost(home: home);
      final good = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({_m1: body, _m2: body}),
        trust: trust,
      );
      expect(good.isOk, isTrue);

      final result = await host.refreshCommunityMetadata(
        transport: FakeMetadataTransport({
          _m1: const CommunityFetchException('network unreachable'),
          _m2: const CommunityFetchException('network unreachable'),
        }),
        trust: trust,
      );
      expect(result.isFailed, isTrue);
      expect(result.errorsByMirror.keys, containsAll([_m1, _m2]));

      // Stale cache intact.
      expect((await host.getCommunityMetadata(_appId))!.summary, 'A test app');
    });

    test('non-https mirror skipped; https mirror still wins', () async {
      final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
      final body = await _signedBody(
        _metadataDoc([_record()]),
        keyPair: keyPair,
        keyId: keyId,
      );
      final transport = FakeMetadataTransport({_m2: body});
      final host = _makeHost(
        home: home,
        flags: {
          'phase3.community.metadata.mirrors': 'http://m1.example/m.json,$_m2',
        },
      );
      final result = await host.refreshCommunityMetadata(
        transport: transport,
        trust: trust,
      );
      expect(result.isOk, isTrue);
      expect(result.mirror, _m2);
      expect(transport.fetched, [_m2]);
    });
  });

  group('getCommunityMetadata', () {
    test('flag off → null despite a valid file on disk', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_metadataDoc([_record()])));
      final host = _makeHost(
        home: home,
        flags: {'phase3.metadata.enabled': false},
      );
      expect(await host.getCommunityMetadata(_appId), isNull);
    });

    test('identity flag off → null despite a valid file on disk', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_metadataDoc([_record()])));
      final host = _makeHost(
        home: home,
        flags: {'phase3.identity.enabled': false},
      );
      expect(await host.getCommunityMetadata(_appId), isNull);
    });

    test('unknown canonical id → null', () async {
      final host = _makeHost(home: home);
      expect(
        await host.getCommunityMetadata(
          const CanonicalAppId(CanonicalIdScheme.appstream, 'org.example.Nope'),
        ),
        isNull,
      );
    });

    test('corrupt file on disk → null, never throws', () async {
      final file = File(_metadataPath(home));
      await file.parent.create(recursive: true);
      await file.writeAsString('{corrupt');
      final host = _makeHost(home: home);
      expect(await host.getCommunityMetadata(_appId), isNull);
    });

    test('alias-follow through the host: metadata keyed by retired '
        'homepage: id found via the identity overlay alias', () async {
      // Metadata keyed by the RETIRED homepage: id.
      final metaFile = File(_metadataPath(home));
      await metaFile.parent.create(recursive: true);
      await metaFile.writeAsString(
        jsonEncode(
          _metadataDoc([
            _record(
              canonicalId: 'homepage:example.org/oldapp',
              summary: 'Old homepage id',
            ),
          ]),
        ),
      );
      // Identity overlay: entry promoted to appstream:, old homepage:
      // id kept as an alias.
      final overlayFile = File(_overlayPath(home));
      await overlayFile.parent.create(recursive: true);
      await overlayFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'source': 'local',
          'entries': [
            {
              'canonicalId': 'appstream:org.example.OldApp',
              'displayName': 'Old App',
              'appstreamIds': <String>[],
              'homepages': <String>[],
              'backends': <String, Object?>{},
              'provenance': {'source': 'local'},
            },
          ],
          'aliases': {
            'homepage:example.org/oldapp': 'appstream:org.example.OldApp',
          },
        }),
      );
      final host = _makeHost(home: home);
      const promoted = CanonicalAppId(
        CanonicalIdScheme.appstream,
        'org.example.OldApp',
      );
      final found = await host.getCommunityMetadata(promoted);
      expect(found, isNotNull);
      expect(found!.summary, 'Old homepage id');
    });
  });

  group('reloadCommunityMetadata', () {
    test('reload before first load is a no-op, never throws', () {
      final host = _makeHost(home: home);
      host.reloadCommunityMetadata();
    });

    test(
      'hand-edited file → reload → lookup reflects it; no restart',
      () async {
        final file = File(_metadataPath(home));
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode(_metadataDoc([_record(summary: 'v1')])),
        );
        final host = _makeHost(home: home);
        expect((await host.getCommunityMetadata(_appId))!.summary, 'v1');

        await file.writeAsString(
          jsonEncode(_metadataDoc([_record(summary: 'v2')])),
        );
        // Cached store still says v1…
        expect((await host.getCommunityMetadata(_appId))!.summary, 'v1');

        // …until the reload drops the cache.
        host.reloadCommunityMetadata();
        expect((await host.getCommunityMetadata(_appId))!.summary, 'v2');
      },
    );

    test(
      'independent of reloadIdentityIndex: neither clobbers the other',
      () async {
        final (:trust, :keyPair, :keyId) = await _ephemeralTrust();
        final body = await _signedBody(
          _metadataDoc([_record()]),
          keyPair: keyPair,
          keyId: keyId,
        );
        // Identity layer: overlay maps metadatatest/handwritten-app.
        final overlayFile = File(_overlayPath(home));
        await overlayFile.parent.create(recursive: true);
        await overlayFile.writeAsString(
          jsonEncode({
            'schemaVersion': 1,
            'source': 'local',
            'entries': [
              {
                'canonicalId': 'appstream:org.example.Handwritten',
                'displayName': 'Handwritten',
                'appstreamIds': <String>[],
                'homepages': <String>[],
                'backends': {
                  'metadatatest': ['handwritten-app'],
                },
                'provenance': {'source': 'local'},
              },
            ],
          }),
        );
        final host = _makeHost(home: home);
        final refresh = await host.refreshCommunityMetadata(
          transport: FakeMetadataTransport({_m1: body}),
          trust: trust,
        );
        expect(refresh.isOk, isTrue);
        const handwritten = CanonicalAppId(
          CanonicalIdScheme.appstream,
          'org.example.Handwritten',
        );
        const id = AppIdentity(
          backendId: 'metadatatest',
          nativeId: 'handwritten-app',
        );
        expect(await host.resolveIdentity(id), handwritten);
        expect(await host.getCommunityMetadata(_appId), isNotNull);

        // Dropping the identity cache leaves metadata alone…
        host.reloadIdentityIndex();
        expect(await host.getCommunityMetadata(_appId), isNotNull);
        // …and the identity index rebuilds from disk.
        expect(await host.resolveIdentity(id), handwritten);

        // Dropping the metadata cache leaves identity alone…
        host.reloadCommunityMetadata();
        expect(await host.resolveIdentity(id), handwritten);
        // …and metadata rebuilds from disk.
        expect(await host.getCommunityMetadata(_appId), isNotNull);
      },
    );
  });
}
