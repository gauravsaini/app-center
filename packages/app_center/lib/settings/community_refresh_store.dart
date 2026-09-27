import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xdg_directories/xdg_directories.dart' as xdg;

/// UI-side record of community index refresh attempts
/// (docs/architecture/phase3-slice4.md §4).
///
/// This is *UI state* — "when did the user last tap refresh and what
/// happened" — not host state. The host owns the community layer file
/// itself; this store only remembers the last attempt for display
/// ("Last refresh: …", "N mirrors configured, mirror X won").
///
/// File: `<xdg.dataHome>/libreapp-center/community-refresh.json` — the
/// same `$HOME/.local/share/libreapp-center/` convention the host uses
/// for its layer files (phase3-slice3.md §5), so the data lives next to
/// the thing it describes.
///
/// Never throws: a missing/corrupt/unparseable file loads as null, and
/// a failed save is dropped silently. A settings display must never
/// crash the page because a JSON file is malformed.
class CommunityRefreshStore {
  /// The XDG data home override. Production passes null (uses
  /// [xdg.dataHome]); tests inject a temp dir.
  CommunityRefreshStore({@visibleForTesting this._baseDir});

  final String? _baseDir;

  String get _path => p.join(
    _baseDir ?? xdg.dataHome.path,
    'libreapp-center',
    'community-refresh.json',
  );

  /// Loads the last recorded refresh, or null when there is none
  /// (never refreshed, missing file, or unparseable content).
  Future<CommunityRefreshRecord?> load() async {
    try {
      final file = File(_path);
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, Object?>) return null;
      return CommunityRefreshRecord.fromJson(raw);
    } on Object catch (_) {
      return null;
    }
  }

  /// Records a refresh outcome. Best-effort: never throws.
  Future<void> save(CommunityRefreshRecord record) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(record.toJson()));
    } on Object catch (_) {
      // Display state only — a failed save must not surface to the UI.
    }
  }
}

/// One recorded community index refresh attempt.
@immutable
class CommunityRefreshRecord {
  const CommunityRefreshRecord({
    required this.attemptedAt,
    this.succeededAt,
    this.mirror,
    this.entryCount,
  });

  /// When the refresh was attempted (always set).
  final DateTime attemptedAt;

  /// When a refresh last fully succeeded (doc verified + installed).
  /// Null when no refresh has ever succeeded.
  final DateTime? succeededAt;

  /// The mirror URL whose doc won the last successful refresh.
  final String? mirror;

  /// Entry count of the last successfully installed doc.
  final int? entryCount;

  static CommunityRefreshRecord? fromJson(Map<String, Object?> json) {
    try {
      final attemptedAt = DateTime.tryParse(
        json['attemptedAt'] as String? ?? '',
      );
      if (attemptedAt == null) return null;
      final succeededRaw = json['succeededAt'] as String?;
      return CommunityRefreshRecord(
        attemptedAt: attemptedAt,
        succeededAt: succeededRaw == null
            ? null
            : DateTime.tryParse(succeededRaw),
        mirror: json['mirror'] as String?,
        entryCount: (json['entryCount'] as num?)?.toInt(),
      );
    } on Object catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'attemptedAt': attemptedAt.toIso8601String(),
    if (succeededAt != null) 'succeededAt': succeededAt!.toIso8601String(),
    if (mirror != null) 'mirror': mirror,
    if (entryCount != null) 'entryCount': entryCount,
  };
}
