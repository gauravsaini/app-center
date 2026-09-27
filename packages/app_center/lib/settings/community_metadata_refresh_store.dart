import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xdg_directories/xdg_directories.dart' as xdg;

/// UI-side record of community *metadata* refresh attempts
/// (docs/architecture/phase3-slice6.md §3).
///
/// Parallel to the identity-index refresh store (`CommunityRefreshStore`),
/// not an extension of it: the two refresh flows are independent
/// (separate docs, separate flags, separate mirrors), and sharing one
/// file would couple their failure modes. Same never-throws contract:
/// a missing/corrupt/unparseable file loads as null, a failed save is
/// dropped silently.
///
/// File: `<xdg.dataHome>/libreapp-center/community-metadata-refresh.json`.
class CommunityMetadataRefreshStore {
  /// The XDG data home override. Production passes null (uses
  /// [xdg.dataHome]); tests inject a temp dir.
  CommunityMetadataRefreshStore({@visibleForTesting this._baseDir});

  final String? _baseDir;

  String get _path => p.join(
    _baseDir ?? xdg.dataHome.path,
    'libreapp-center',
    'community-metadata-refresh.json',
  );

  /// Loads the last recorded metadata refresh, or null when there is
  /// none (never refreshed, missing file, or unparseable content).
  Future<CommunityMetadataRefreshRecord?> load() async {
    try {
      final file = File(_path);
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, Object?>) return null;
      return CommunityMetadataRefreshRecord.fromJson(raw);
    } on Object catch (_) {
      return null;
    }
  }

  /// Records a metadata refresh outcome. Best-effort: never throws.
  Future<void> save(CommunityMetadataRefreshRecord record) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(record.toJson()));
    } on Object catch (_) {
      // Display state only — a failed save must not surface to the UI.
    }
  }
}

/// One recorded community metadata refresh attempt.
@immutable
class CommunityMetadataRefreshRecord {
  const CommunityMetadataRefreshRecord({
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

  /// Metadata-record count of the last successfully installed doc.
  final int? entryCount;

  static CommunityMetadataRefreshRecord? fromJson(Map<String, Object?> json) {
    try {
      final attemptedAt = DateTime.tryParse(
        json['attemptedAt'] as String? ?? '',
      );
      if (attemptedAt == null) return null;
      final succeededRaw = json['succeededAt'] as String?;
      return CommunityMetadataRefreshRecord(
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
