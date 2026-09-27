/// Ed25519 signature verification for community index docs
/// (Phase 3 identity, slice 3).
///
/// Implements `docs/architecture/phase3-slice3.md` §2–§3.
///
/// Strictness lives here: every verification failure — bad envelope
/// shape, unknown keyId, bad algorithm, bad signature bytes, failed
/// verify — throws [CommunitySignatureException] with a message that
/// says WHAT failed, never key material. The trust roots are pinned in
/// [CommunityTrustStore]; there is no TOFU.
///
/// The canonical form (§2.2) is specified in this slice precisely so a
/// non-Dart publisher can reproduce it: object keys sorted by code-unit
/// order, recursively; no whitespace; RFC 8259 string escaping;
/// numbers in `jsonEncode` form; `true`/`false`/`null` lowercase.
///
/// Host-internal plumbing: not exported from `store_host.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Canonical JSON bytes of [doc]: keys sorted recursively (code-unit
/// order), no whitespace, RFC 8259 string escaping. Deterministic —
/// the same logical document always yields the same bytes, no matter
/// which mirror served it or how it was pretty-printed.
Uint8List canonicalJsonBytes(Map<String, Object?> doc) {
  final sb = StringBuffer();
  _writeCanonical(sb, doc);
  return Uint8List.fromList(utf8.encode(sb.toString()));
}

void _writeCanonical(StringBuffer sb, Object? value) {
  switch (value) {
    case null:
      sb.write('null');
    case true:
      sb.write('true');
    case false:
      sb.write('false');
    case String s:
      _writeEscapedString(sb, s);
    case num n:
      // Numbers in jsonEncode form. The index schema uses strings and
      // ints only; doubles are not expected.
      sb.write(jsonEncode(n));
    case List l:
      sb.write('[');
      for (var i = 0; i < l.length; i++) {
        if (i > 0) sb.write(',');
        _writeCanonical(sb, l[i]);
      }
      sb.write(']');
    case Map m:
      // Sort keys by code-unit order, recursively.
      final keys = m.keys.map((k) => k as String).toList()..sort();
      sb.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) sb.write(',');
        _writeEscapedString(sb, keys[i]);
        sb.write(':');
        _writeCanonical(sb, m[keys[i]]);
      }
      sb.write('}');
    default:
      throw FormatException(
        'Cannot canonicalize value of type ${value.runtimeType}',
      );
  }
}

void _writeEscapedString(StringBuffer sb, String s) {
  sb.write('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    switch (c) {
      case 0x22:
        sb.write(r'\"');
      case 0x5C:
        sb.write(r'\\');
      case 0x08:
        sb.write(r'\b');
      case 0x0C:
        sb.write(r'\f');
      case 0x0A:
        sb.write(r'\n');
      case 0x0D:
        sb.write(r'\r');
      case 0x09:
        sb.write(r'\t');
      default:
        if (c < 0x20) {
          sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          sb.writeCharCode(c);
        }
    }
  }
  sb.write('"');
}

/// Signature envelope from a community index doc's `signature` field.
///
/// [CommunitySignature.parse] throws [FormatException] on bad shape:
/// non-Map, or missing/non-String `keyId`, `algorithm`, or `sig`.
class CommunitySignature {
  const CommunitySignature({
    required this.keyId,
    required this.algorithm,
    required this.sig,
  });

  /// Parses [json] as a signature envelope. Throws [FormatException]
  /// when [json] is not a Map or any of the three fields is missing
  /// or not a String.
  factory CommunitySignature.parse(Map<String, Object?> json) {
    final keyId = json['keyId'];
    final algorithm = json['algorithm'];
    final sig = json['sig'];
    if (keyId is! String) {
      throw FormatException(
        'Signature envelope has missing or non-string keyId',
      );
    }
    if (algorithm is! String) {
      throw FormatException(
        'Signature envelope has missing or non-string algorithm',
      );
    }
    if (sig is! String) {
      throw FormatException('Signature envelope has missing or non-string sig');
    }
    return CommunitySignature(keyId: keyId, algorithm: algorithm, sig: sig);
  }

  /// Envelope key selecting the pinned public key.
  final String keyId;

  /// Must be exactly `'ed25519'`.
  final String algorithm;

  /// The signature, base64-encoded (64 bytes when decoded).
  final String sig;
}

/// Pinned trust roots for community index verification. No TOFU —
///
/// [bootstrap] holds ONE placeholder key: keyId
/// `'libreapp-index-bootstrap'`. The 32 bytes are random placeholder
/// data, and the private half is held by nobody. This key exists so
/// the verify path, keyId lookup, and tamper rejection machinery is
/// real and fully tested with ephemeral test keys; it must be
/// REPLACED at the project's key ceremony before publishing any real
/// index. Shipping a real-looking key nobody controls would be
/// dishonest; shipping the format with a labeled placeholder is not.
///
/// Rotation is overlap: pin the new key in an app update, curators
/// start signing with the new key, the old key is removed in a later
/// update. There is no in-band revocation or expiry in v1.
class CommunityTrustStore {
  const CommunityTrustStore(this.keys);

  /// Placeholder trust store. REPLACE at the key ceremony — see the
  /// class docs.
  static const bootstrap = CommunityTrustStore({
    // PLACEHOLDER — replace at the project's key ceremony before
    // publishing any real index; the private half is held by nobody.
    'libreapp-index-bootstrap': 'kP3vN9qR8sT2wX4yZ6aB1cD5eF7gH0iJ3kL5mN7oP9q=',
  });

  /// keyId → base64 public key (32 raw bytes when decoded).
  final Map<String, String> keys;
}

/// Thrown for every verification failure (bad shape, unknown keyId,
/// bad algorithm, bad signature bytes, failed verify). The message
/// says WHAT failed, never key material.
class CommunitySignatureException implements Exception {
  const CommunitySignatureException(this.message);

  final String message;

  @override
  String toString() => 'CommunitySignatureException: $message';
}

/// A verified community doc: the envelope stripped, ready to merge.
class VerifiedCommunityDoc {
  const VerifiedCommunityDoc({
    required this.doc,
    required this.keyId,
    this.generatedAt,
  });

  /// The doc with the `signature` envelope removed.
  final Map<String, Object?> doc;

  /// The keyId whose pinned key verified it.
  final String keyId;

  /// Parsed from `doc['generatedAt']`; null when absent or
  /// unparseable. Informational only (staleness display) — never a
  /// freshness gate (§1).
  final DateTime? generatedAt;
}

/// Verifies a downloaded community doc.
///
/// Steps:
/// 1. [raw] must contain a `signature` object — unsigned docs never
///    merge (missing → throw).
/// 2. Parse the envelope ([CommunitySignature.parse]).
/// 3. `algorithm` must be exactly `'ed25519'`.
/// 4. `sig` must base64-decode to 64 bytes.
/// 5. `keyId` must be pinned in [trust]; the pinned key must
///    base64-decode to 32 bytes.
/// 6. Verify Ed25519 over `canonicalJsonBytes(raw minus envelope)`.
///
/// Any failure throws [CommunitySignatureException]. Success returns
/// [VerifiedCommunityDoc] with the envelope stripped, ready to merge.
Future<VerifiedCommunityDoc> verifyCommunityDoc(
  Map<String, Object?> raw,
  CommunityTrustStore trust,
) async {
  // Copy minus the envelope so canonicalization never sees it.
  final doc = Map<String, Object?>.of(raw);
  final envelopeJson = doc.remove('signature');
  if (envelopeJson is! Map<String, Object?>) {
    throw const CommunitySignatureException(
      'Community doc rejected: unsigned docs never merge (missing '
      '`signature` object)',
    );
  }

  final CommunitySignature envelope;
  try {
    envelope = CommunitySignature.parse(envelopeJson);
  } on FormatException catch (e) {
    throw CommunitySignatureException(
      'Community doc rejected: malformed signature envelope (${e.message})',
    );
  }

  if (envelope.algorithm != 'ed25519') {
    throw CommunitySignatureException(
      'Community doc rejected: unsupported signature algorithm '
      "'${envelope.algorithm}' (only 'ed25519' is accepted)",
    );
  }

  final sigBytes = _decodeBase64(
    envelope.sig,
    what: 'signature bytes',
    expectedLength: 64,
  );
  final pinnedKey = trust.keys[envelope.keyId];
  if (pinnedKey == null) {
    throw CommunitySignatureException(
      "Community doc rejected: unknown signature keyId '${envelope.keyId}' "
      '(not pinned in the trust store)',
    );
  }
  final pubkeyBytes = _decodeBase64(
    pinnedKey,
    what: 'pinned public key',
    expectedLength: 32,
  );

  final message = canonicalJsonBytes(doc);
  final ok = await Ed25519().verify(
    message,
    signature: Signature(
      sigBytes,
      publicKey: SimplePublicKey(pubkeyBytes, type: KeyPairType.ed25519),
    ),
  );
  if (!ok) {
    throw CommunitySignatureException(
      "Community doc rejected: signature does not verify with keyId "
      "'${envelope.keyId}'",
    );
  }

  return VerifiedCommunityDoc(
    doc: doc,
    keyId: envelope.keyId,
    generatedAt: _parseGeneratedAt(doc),
  );
}

Uint8List _decodeBase64(
  String encoded, {
  required String what,
  required int expectedLength,
}) {
  late final List<int> bytes;
  try {
    bytes = base64.decode(encoded);
  } on FormatException {
    throw CommunitySignatureException(
      'Community doc rejected: $what is not valid base64',
    );
  }
  if (bytes.length != expectedLength) {
    throw CommunitySignatureException(
      'Community doc rejected: $what decoded to ${bytes.length} bytes '
      '(expected $expectedLength)',
    );
  }
  return Uint8List.fromList(bytes);
}

DateTime? _parseGeneratedAt(Map<String, Object?> doc) {
  final raw = doc['generatedAt'];
  if (raw is! String) return null;
  return DateTime.tryParse(raw);
}
