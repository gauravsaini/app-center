/// Filename heuristics, `.desktop` parsing, the version fallback chain,
/// and the managed `.desktop` file template.
///
/// Filename parsing is documented as heuristic (LLD §5): the `.desktop`
/// entry's keys always win when extraction succeeds.
library;

/// ELF magic + AppImage type magic at offset 8 (spec draft §1.2).
/// This — never the file extension — decides what an AppImage is.
bool isAppImageMagic(List<int> head) {
  if (head.length < 11) return false;
  return head[0] == 0x7F &&
      head[1] == 0x45 && // 'E'
      head[2] == 0x4C && // 'L'
      head[3] == 0x46 && // 'F'
      head[8] == 0x41 && // 'A'
      head[9] == 0x49 && // 'I'
      (head[10] == 0x01 || head[10] == 0x02); // AI\x01 | AI\x02
}

/// Filename-derived display metadata.
class FilenameMeta {
  const FilenameMeta({required this.name, this.version});

  final String name;
  final String? version;
}

/// Trailing architecture token, peeled before version detection — it may
/// itself contain separators (`x86_64`), so this runs on the whole stem.
final _archSuffix = RegExp(
  r'[-_.](?:x86_64|aarch64|arm64|i386|i686|amd64|armhf|x64)$',
  caseSensitive: false,
);

/// Trailing version token: `[-_.]v?1.2.3` or a named channel
/// (`continuous`, …). Group 1 is the version without the separator.
final _versionSuffix = RegExp(
  r'[-_.](v?\d+(?:\.\d+)*|continuous|latest|nightly|dev|stable)$',
  caseSensitive: false,
);

/// Parse `Name-Version-arch.AppImage` (also `_`/`.` separators, optional
/// parts). E.g. `Kdenlive-24.08.3-x86_64.AppImage` → name `Kdenlive`,
/// version `24.08.3`. Unparseable → basename minus extension, null version.
///
/// Documented as heuristic (LLD §5): `.desktop` data wins when available.
FilenameMeta parseFilename(String basename) {
  var stem = basename;
  final extIdx = stem.toLowerCase().lastIndexOf('.appimage');
  if (extIdx >= 0) stem = stem.substring(0, extIdx);
  stem = stem.replaceFirst(_archSuffix, '');
  String? version;
  final vMatch = _versionSuffix.firstMatch(stem);
  if (vMatch != null) {
    version = vMatch.group(1);
    stem = stem.substring(0, vMatch.start);
  }
  final name = stem
      .split(RegExp(r'[-_.]'))
      .where((p) => p.isNotEmpty)
      .join(' ');
  return FilenameMeta(name: name.isEmpty ? basename : name, version: version);
}

/// Parse a `.desktop` file into the `[Desktop Entry]` section's keys.
/// Falls back to the first section carrying keys when `[Desktop Entry]`
/// is absent; `{}` for unparseable input. Never throws.
Map<String, String> parseDesktopFile(String content) {
  final sections = <String, Map<String, String>>{};
  String? section;
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']') && line.length > 2) {
      section = line.substring(1, line.length - 1);
      sections.putIfAbsent(section, () => {});
      continue;
    }
    final idx = line.indexOf('=');
    if (idx <= 0 || section == null) continue;
    sections[section]![line.substring(0, idx).trim()] = line
        .substring(idx + 1)
        .trim();
  }
  if (sections.containsKey('Desktop Entry')) {
    return sections['Desktop Entry']!;
  }
  return sections.values.isEmpty ? {} : sections.values.first;
}

/// Version fallback chain (research §1.1): `X-AppImage-Version` (most
/// trustworthy when present) → `Version` → filename → null.
/// Never invents a version.
String? versionFallback({
  String? xAppImageVersion,
  String? desktopVersion,
  String? filenameVersion,
}) {
  for (final v in [xAppImageVersion, desktopVersion, filenameVersion]) {
    if (v != null && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// Render the managed `.desktop` file install() writes to
/// `~/.local/share/applications/appimage-<slug>.desktop`.
///
/// The `appimage-` prefix avoids shadowing a distro package's entry of
/// the same name; `X-LibreStore-*` provenance keys let remove()/repair
/// identify exactly our own files.
String renderDesktopFile({
  required String name,
  String? comment,
  required String execPath,
  String? iconPath,
  String? categories,
  required String sha,
}) {
  final cats = categories == null || categories.trim().isEmpty
      ? 'Utility;'
      : categories.trim().endsWith(';')
      ? categories.trim()
      : '${categories.trim()};';
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=$name\n'
      'Comment=${comment ?? ''}\n'
      'Exec="$execPath" %U\n'
      'Icon=${iconPath ?? ''}\n'
      'Categories=$cats\n'
      'X-LibreStore-Backend=appimage\n'
      'X-LibreStore-Identity=$sha\n'
      'X-LibreStore-Managed=true\n';
}
