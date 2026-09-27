/// AppImage identity: content-addressed sha256 plus the in-memory index.
///
/// There is no central AppImage registry, so identity is the file's
/// sha256 hex digest — stable across moves, renames, and copies. The
/// install-copy keeps the same identity as the source file.
library;

/// One indexed AppImage: where the file lives plus filename-derived
/// display metadata (heuristic — `.desktop` data wins when available).
class IndexedApp {
  const IndexedApp({
    required this.sha,
    required this.path,
    required this.size,
    required this.mtimeMs,
    required this.name,
    this.version,
  });

  /// Lowercase hex sha256 of the file content; the [AppIdentity.nativeId].
  final String sha;
  final String path;
  final int size;
  final int mtimeMs;

  /// Filename-derived display name (heuristic).
  final String name;

  /// Filename-derived version; null when the filename carries none.
  /// Never invented.
  final String? version;
}

/// Cache key for the sha256: re-hash a file only when it changed.
String indexCacheKey(String path, int size, int mtimeMs) =>
    '$path|$size|$mtimeMs';

/// Lowercase-alnum slug for generated file names, truncated to 48 chars.
/// Falls back to `'app'` when nothing alphanumeric survives.
String slugify(String name) {
  var slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 48) {
    slug = slug.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
  }
  return slug.isEmpty ? 'app' : slug;
}
