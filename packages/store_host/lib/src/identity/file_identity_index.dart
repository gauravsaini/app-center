/// [FileIdentityIndexStore]: layered [IdentityIndex] loading with
/// local-overlay persistence (Phase 3 identity, slice 1).
///
/// Implements `docs/architecture/phase3-identity-lld.md` §5.2.
/// Host-internal plumbing: not exported from `store_host.dart`.
///
/// Forgiveness lives at this layer: [load] never throws for I/O or JSON
/// problems (missing/unparseable files are skipped; worst case the
/// caller gets the seed-only, possibly empty, index). Strictness lives
/// at the parse layer ([IdentityIndex.fromJsonDocs] counts skipped
/// docs). [saveOverlay] is the one throwing path: it writes user data
/// and can only fail on unrecoverable I/O (disk full, permission),
/// reported as [StateError] with the path in the message.
library;

import 'dart:convert';
import 'dart:io';

import 'package:store_contracts/store_contracts.dart';

class FileIdentityIndexStore {
  /// Loads the layered index: the bundled [seedJson] first (lowest
  /// priority), then each of [overlayPaths] that exists and parses.
  /// Missing, unreadable, or unparseable files are skipped —
  /// individually, never fatally. Worst case returns the seed-only
  /// index (possibly empty, when the seed itself is garbage).
  ///
  /// Never throws for I/O or JSON problems.
  Future<IdentityIndex> load({
    required String seedJson,
    List<String> overlayPaths = const [],
  }) async {
    final docs = <Map<String, Object?>>[];
    final seedDoc = _tryParseDoc(seedJson);
    if (seedDoc != null) docs.add(seedDoc);
    for (final path in overlayPaths) {
      final doc = await _tryReadDoc(path);
      if (doc != null) docs.add(doc);
    }
    return IdentityIndex.fromJsonDocs(docs);
  }

  /// Writes [entries] as a single overlay doc
  /// `{schemaVersion: 1, source: 'local', entries: [...]}` to [path],
  /// creating parent directories as needed. Entries serialize in the
  /// canonical form ([CanonicalEntry.toJson]).
  ///
  /// Throws [StateError] (with the path in the message) only on
  /// unrecoverable I/O — disk full, permission denied, no write
  /// access to the parent.
  Future<void> saveOverlay(String path, List<CanonicalEntry> entries) async {
    final doc = <String, Object?>{
      'schemaVersion': 1,
      'source': 'local',
      'entries': [for (final e in entries) e.toJson()],
    };
    final file = File(path);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(doc));
    } on IOException catch (e) {
      // FileSystemException (missing dir, permission, disk full) is an
      // IOException subtype — one catch covers every I/O failure.
      throw StateError('cannot write identity overlay at $path: $e');
    }
  }

  /// Parses a JSON string into an overlay doc shape, or null when the
  /// string is not a JSON object. (Malformed-but-parseable docs are
  /// handled — skipped and counted — by [IdentityIndex.fromJsonDocs].)
  static Map<String, Object?>? _tryParseDoc(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
    } on FormatException {
      // Unparseable: skip.
    }
    return null;
  }

  /// Reads one overlay file into a doc, or null when the file is
  /// missing, unreadable, or unparseable.
  static Future<Map<String, Object?>?> _tryReadDoc(String path) async {
    try {
      return _tryParseDoc(await File(path).readAsString());
    } on IOException {
      // Missing/unreadable file, path is a directory, permission
      // denied: all skip, none throw.
      return null;
    }
  }
}
