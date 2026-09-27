/// [SourcePreferenceStore]: per-app remembered source preference
/// (docs/architecture/phase3-slice2.md §4, HLD §6 rule 2).
///
/// Host-internal plumbing: not exported from `store_host.dart`.
///
/// Shape: `{canonicalIdString: backendId}`, e.g.
/// `{'appstream:org.mozilla.firefox': 'deb'}`.
///
/// Forgiveness lives at the load layer (same contract as
/// [FileIdentityIndexStore]): [load] never throws for I/O or JSON
/// problems (missing/corrupt file → empty preferences). [setPreferred]
/// persists user data and throws [StateError] only on unrecoverable I/O
/// (disk full, permission denied). Unknown backend ids are stored
/// verbatim and ignored at ordering time — never validated here.
library;

import 'dart:convert';
import 'dart:io';

class SourcePreferenceStore {
  /// [filePath] overrides the default preferences file (tests).
  /// When null, the path resolves from `HOME` at call time:
  /// `~/.local/share/libreapp-center/source-preferences.json`. A
  /// missing/empty `HOME` means in-memory only (nothing is read or
  /// written).
  SourcePreferenceStore({String? filePath}) : _filePath = filePath;

  final String? _filePath;

  /// canonical id string → backend id, verbatim as stored.
  final Map<String, String> _prefs = {};

  /// Loads preferences from disk into memory. Never throws: a missing,
  /// unreadable, or unparseable file yields empty preferences (same
  /// forgiveness contract as the identity index store).
  Future<void> load() async {
    _prefs.clear();
    final path = _resolvedPath();
    if (path == null) return;
    try {
      final decoded = jsonDecode(await File(path).readAsString());
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final key = entry.key;
          final value = entry.value;
          // Verbatim storage: both sides must be non-empty strings.
          // Anything else is corrupt data — skipped, never fatal.
          if (key is String && key.isNotEmpty && value is String) {
            if (value.isNotEmpty) _prefs[key] = value;
          }
        }
      }
    } on IOException {
      // Missing/unreadable file: in-memory stays empty.
    } on FormatException {
      // Unparseable JSON: in-memory stays empty.
    }
  }

  /// The remembered backend for [canonicalIdString], or null when the
  /// user picked nothing. Returned verbatim: callers must treat an id
  /// no backend recognizes as "no preference" (ordering ignores it).
  String? preferenceFor(String canonicalIdString) => _prefs[canonicalIdString];

  /// Remembers [backendId] as the user's choice for
  /// [canonicalIdString] and persists it. [backendId] is stored
  /// verbatim (never validated): an id no backend recognizes is kept
  /// and ignored at ordering time.
  ///
  /// Throws [StateError] (path in the message) only on unrecoverable
  /// I/O — disk full, permission denied, no write access to the
  /// parent.
  Future<void> setPreferred(String canonicalIdString, String backendId) async {
    _prefs[canonicalIdString] = backendId;
    await _save();
  }

  Future<void> _save() async {
    final path = _resolvedPath();
    if (path == null) return; // In-memory only: nothing to persist.
    final file = File(path);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_prefs));
    } on IOException catch (e) {
      // FileSystemException (missing dir, permission, disk full) is an
      // IOException subtype — one catch covers every I/O failure.
      throw StateError('cannot write source preferences at $path: $e');
    }
  }

  String? _resolvedPath() {
    if (_filePath != null) return _filePath;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.local/share/libreapp-center/source-preferences.json';
  }
}
