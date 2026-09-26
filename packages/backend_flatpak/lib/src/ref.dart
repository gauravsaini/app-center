/// Flatpak ref parsing: `app/org.videolan.VLC/x86_64/stable`
/// or a bare application id `org.videolan.VLC`.
library;

/// A parsed flatpak ref.
class FlatpakRef {
  const FlatpakRef({
    required this.kind,
    required this.id,
    required this.arch,
    required this.branch,
  });

  /// 'app' or 'runtime'.
  final String kind;
  final String id;
  final String arch;
  final String branch;

  /// Full ref string, e.g. `app/org.videolan.VLC/x86_64/stable`.
  String get ref => '$kind/$id/$arch/$branch';

  /// Parse a full ref or a bare application id.
  /// Bare ids default to `app/<id>/x86_64/stable`.
  factory FlatpakRef.parse(String s) {
    final parts = s.split('/');
    if (parts.length == 4 && (parts[0] == 'app' || parts[0] == 'runtime')) {
      return FlatpakRef(
        kind: parts[0],
        id: parts[1],
        arch: parts[2],
        branch: parts[3],
      );
    }
    if (parts.length == 1 && s.contains('.')) {
      return FlatpakRef(kind: 'app', id: s, arch: 'x86_64', branch: 'stable');
    }
    throw FormatException('not a flatpak ref or app id: $s');
  }

  @override
  String toString() => ref;

  @override
  bool operator ==(Object other) =>
      other is FlatpakRef &&
      other.kind == kind &&
      other.id == id &&
      other.arch == arch &&
      other.branch == branch;

  @override
  int get hashCode => Object.hash(kind, id, arch, branch);
}
