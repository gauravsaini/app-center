/// pacman metadata presentation: version display and size parsing.
///
/// The version is opaque — shown verbatim, never split into
/// epoch/version/release and never "prettified".
library;

final _sizeRe = RegExp(r'^([\d.]+)\s*([A-Za-z]+)$');

/// The version string the UI shows: the version verbatim (epoch prefix
/// included), or null when pacman emitted none. Never invents a version.
String? displayVersion(String version) => version.isEmpty ? null : version;

/// Parse pacman's `%.2f <unit>` size strings (`585.77 KiB`) into bytes.
/// Units are B/KiB/MiB/GiB, case-insensitive (tux_store rule,
/// research §2.3). Unrecognized input → 0, never a throw — a weird
/// size string must not fail a details page.
int parseSize(String? raw) {
  if (raw == null) return 0;
  final m = _sizeRe.firstMatch(raw.trim());
  if (m == null) return 0;
  final value = double.tryParse(m.group(1)!);
  if (value == null) return 0;
  final multiplier = switch (m.group(2)!.toLowerCase()) {
    'b' => 1,
    'kib' => 1024,
    'mib' => 1024 * 1024,
    'gib' => 1024 * 1024 * 1024,
    _ => 0,
  };
  if (multiplier == 0) return 0;
  return (value * multiplier).round();
}
