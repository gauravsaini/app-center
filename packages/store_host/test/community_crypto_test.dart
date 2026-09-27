/// Tests for community index signature verification (slice 3, leaf A).
///
/// All keys are generated ephemerally in-test with the real
/// `cryptography` Ed25519 — the placeholder bootstrap key is never
/// used. No network, no filesystem.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:store_host/src/identity/community_crypto.dart';
import 'package:test/test.dart';

/// Generates an ephemeral Ed25519 keypair and returns the trust store
/// pinning it under [keyId], plus the keypair for signing.
Future<({CommunityTrustStore trust, SimpleKeyPair keyPair, String keyId})>
ephemeralTrust({String keyId = 'test-key'}) async {
  final keyPair = await Ed25519().newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final pubBytes = publicKey.bytes;
  return (
    trust: CommunityTrustStore({keyId: base64.encode(pubBytes)}),
    keyPair: keyPair,
    keyId: keyId,
  );
}

/// Signs [doc] (minus any existing `signature`) with [keyPair] under
/// [keyId], returning the doc with a valid `signature` envelope.
Future<Map<String, Object?>> signDoc(
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
  return body;
}

void main() {
  group('canonicalJsonBytes', () {
    test('sorts keys and strips whitespace', () {
      final bytes = canonicalJsonBytes({
        'z': 1,
        'a': {'d': 2, 'b': 3},
        'm': 'x',
      });
      expect(utf8.decode(bytes), '{"a":{"b":3,"d":2},"m":"x","z":1}');
    });

    test('sorts nested maps and lists of maps', () {
      final bytes = canonicalJsonBytes({
        'list': [
          {'z': 1, 'a': 2},
          {'b': 3},
        ],
      });
      expect(utf8.decode(bytes), '{"list":[{"a":2,"z":1},{"b":3}]}');
    });

    test('escapes strings per RFC 8259', () {
      final bytes = canonicalJsonBytes({
        'q': 'a"b\\c\nd\te',
        'ctrl': '\u0001\u001f',
        'unicode': 'héllo→世界',
      });
      expect(
        utf8.decode(bytes),
        '{"ctrl":"\\u0001\\u001f","q":"a\\"b\\\\c\\nd\\te","unicode":"héllo→世界"}',
      );
    });

    test('handles null, bools, nested escaping deterministically', () {
      final doc = {'n': null, 't': true, 'f': false, 'i': 42, 's': 'plain'};
      final a = canonicalJsonBytes(doc);
      final b = canonicalJsonBytes(Map<String, Object?>.of(doc));
      expect(
        utf8.decode(a),
        '{"f":false,"i":42,"n":null,"s":"plain","t":true}',
      );
      expect(a, b, reason: 'stability across encodings of the same doc');
    });

    test('any value change changes the bytes', () {
      final base = canonicalJsonBytes({
        'entries': [
          {'id': 'appstream:org.mozilla.firefox', 'version': '1'},
        ],
      });
      final changed = canonicalJsonBytes({
        'entries': [
          {'id': 'appstream:org.mozilla.firefox', 'version': '2'},
        ],
      });
      expect(base, isNot(equals(changed)));
    });
  });

  group('CommunitySignature.parse', () {
    test('parses a valid envelope', () {
      final sig = CommunitySignature.parse({
        'keyId': 'k',
        'algorithm': 'ed25519',
        'sig': 'AAAA',
      });
      expect(sig.keyId, 'k');
      expect(sig.algorithm, 'ed25519');
      expect(sig.sig, 'AAAA');
    });

    test('throws FormatException on bad shape', () {
      expect(
        () => CommunitySignature.parse({'keyId': 'k'}),
        throwsFormatException,
      );
      expect(
        () => CommunitySignature.parse({
          'keyId': 'k',
          'algorithm': 42,
          'sig': 'x',
        }),
        throwsFormatException,
      );
      expect(
        () => CommunitySignature.parse({'keyId': 'k', 'algorithm': 'ed25519'}),
        throwsFormatException,
      );
    });
  });

  group('verifyCommunityDoc', () {
    test(
      'valid envelope verifies; envelope stripped; generatedAt parsed',
      () async {
        final fixture = await ephemeralTrust();
        final raw = await signDoc(
          {
            'schemaVersion': 1,
            'generatedAt': '2026-09-28T00:00:00Z',
            'source': 'community',
            'entries': [
              {'id': 'appstream:org.mozilla.firefox', 'name': 'Firefox'},
            ],
          },
          keyPair: fixture.keyPair,
          keyId: fixture.keyId,
        );

        final verified = await verifyCommunityDoc(raw, fixture.trust);

        expect(verified.keyId, fixture.keyId);
        expect(verified.doc.containsKey('signature'), isFalse);
        expect(verified.doc['entries'], [
          {'id': 'appstream:org.mozilla.firefox', 'name': 'Firefox'},
        ]);
        expect(verified.generatedAt, DateTime.utc(2026, 9, 28));
      },
    );

    test('generatedAt null when absent or unparseable', () async {
      final fixture = await ephemeralTrust();
      final noDate = await signDoc(
        {'schemaVersion': 1, 'entries': []},
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      expect(
        (await verifyCommunityDoc(noDate, fixture.trust)).generatedAt,
        isNull,
      );

      final badDate = await signDoc(
        {'schemaVersion': 1, 'generatedAt': 'not-a-date', 'entries': []},
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      expect(
        (await verifyCommunityDoc(badDate, fixture.trust)).generatedAt,
        isNull,
      );
    });

    test('tampered entry is rejected', () async {
      final fixture = await ephemeralTrust();
      final raw = await signDoc(
        {
          'entries': [
            {'id': 'appstream:org.mozilla.firefox', 'name': 'Firefox'},
          ],
        },
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      // Tamper after signing: rename the package mapping.
      final entries = raw['entries'] as List<Object?>;
      (entries[0] as Map<String, Object?>)['name'] = 'TotallyNotFirefox';

      await expectLater(
        verifyCommunityDoc(raw, fixture.trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('does not verify'),
          ),
        ),
      );
    });

    test('signature from the wrong key is rejected', () async {
      final signer = await ephemeralTrust(keyId: 'key-a');
      final other = await ephemeralTrust(keyId: 'key-b');
      // Signed with key-a but verified against a trust store pinning only
      // key-b's public key under the same keyId.
      final trust = CommunityTrustStore({
        signer.keyId: other.trust.keys[other.keyId]!,
      });
      final raw = await signDoc(
        {'entries': []},
        keyPair: signer.keyPair,
        keyId: signer.keyId,
      );

      await expectLater(
        verifyCommunityDoc(raw, trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('does not verify'),
          ),
        ),
      );
    });

    test('unknown keyId is rejected', () async {
      final fixture = await ephemeralTrust();
      final raw = await signDoc(
        {'entries': []},
        keyPair: fixture.keyPair,
        keyId: 'rogue-key-not-pinned',
      );

      await expectLater(
        verifyCommunityDoc(raw, fixture.trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('unknown'),
          ),
        ),
      );
    });

    test('wrong algorithm is rejected', () async {
      final fixture = await ephemeralTrust();
      final raw = await signDoc(
        {'entries': []},
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      (raw['signature'] as Map<String, Object?>)['algorithm'] = 'rsa-sha256';

      await expectLater(
        verifyCommunityDoc(raw, fixture.trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('algorithm'),
          ),
        ),
      );
    });

    test('malformed sig is rejected (not base64 / wrong length)', () async {
      final fixture = await ephemeralTrust();
      final baseDoc = {'entries': <Object?>[]};

      final notBase64 = await signDoc(
        baseDoc,
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      (notBase64['signature'] as Map<String, Object?>)['sig'] = '!!!nope!!!';
      await expectLater(
        verifyCommunityDoc(notBase64, fixture.trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('base64'),
          ),
        ),
      );

      final wrongLength = await signDoc(
        baseDoc,
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      // Valid base64 but only 32 bytes.
      (wrongLength['signature'] as Map<String, Object?>)['sig'] = base64.encode(
        Uint8List(32),
      );
      await expectLater(
        verifyCommunityDoc(wrongLength, fixture.trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('bytes'),
          ),
        ),
      );
    });

    test('missing signature is rejected: unsigned docs never merge', () async {
      final fixture = await ephemeralTrust();
      await expectLater(
        verifyCommunityDoc({'entries': []}, fixture.trust),
        throwsA(
          isA<CommunitySignatureException>().having(
            (e) => e.message,
            'message',
            contains('unsigned'),
          ),
        ),
      );
      await expectLater(
        verifyCommunityDoc({'signature': 'not-an-object'}, fixture.trust),
        throwsA(isA<CommunitySignatureException>()),
      );
    });

    test('exception message never leaks key material', () async {
      final fixture = await ephemeralTrust();
      final raw = await signDoc(
        {'entries': []},
        keyPair: fixture.keyPair,
        keyId: fixture.keyId,
      );
      final sig = (raw['signature'] as Map<String, Object?>)['sig'] as String;
      final pub = fixture.trust.keys[fixture.keyId]!;
      (raw['signature'] as Map<String, Object?>)['sig'] = base64.encode(
        Uint8List(64),
      ); // wrong sig → verify fails

      try {
        await verifyCommunityDoc(raw, fixture.trust);
        fail('expected CommunitySignatureException');
      } on CommunitySignatureException catch (e) {
        expect(e.message, isNot(contains(sig)));
        expect(e.message, isNot(contains(pub)));
      }
    });
  });
}
