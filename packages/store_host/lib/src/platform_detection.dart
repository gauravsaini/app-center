/// Platform detection engine: distro identity parsed from
/// `/etc/os-release`, plus the seed table that turns identity into
/// backend kill-switch defaults
/// (docs/architecture/platform-detection.md).
///
/// Identity only — never liveness. `isAvailable()` remains the runtime
/// truth for whether a backend is usable; detection only seeds flag
/// defaults at startup, and never throws.
library;

import 'dart:io';

import 'flags.dart';

/// Distro identity parsed from `/etc/os-release`. Identity only — never
/// liveness (see platform-detection.md §2).
class PlatformInfo {
  const PlatformInfo({
    required this.id,
    required this.idLike,
    required this.prettyName,
  });

  /// Parse failure (or anything unrecognized): the safe fallback —
  /// seeding nothing, which preserves today's behavior.
  const PlatformInfo.unknown() : id = '', idLike = const [], prettyName = '';

  /// Raw `ID=` field, e.g. `'ubuntu'`. Empty when unknown.
  final String id;

  /// Raw `ID_LIKE=` field split on whitespace, e.g. `['debian']`.
  final List<String> idLike;

  /// Raw `PRETTY_NAME=` — display only, never classified on.
  final String prettyName;

  // Classification rules (platform-detection.md §1), evaluated in this
  // order. The exclusivity chains below make "exactly one predicate is
  // true" hold even for synthetic content matching multiple rules.
  static const _debianIds = {
    'ubuntu',
    'debian',
    'linuxmint',
    'pop',
    'elementary',
    'zorin',
    'kali',
    'raspbian',
  };
  static const _fedoraIds = {
    'fedora',
    'rhel',
    'centos',
    'rocky',
    'almalinux',
    'nobara',
    'opensuse-leap',
    'opensuse-tumbleweed',
    'sles',
  };
  static const _archIds = {'arch', 'manjaro', 'endeavouros', 'garuda', 'artix'};

  /// Rule 1: Debian family — `ID` in the table (covers derivatives that
  /// forget `ID_LIKE`) or `ID_LIKE` containing `debian`/`ubuntu`.
  bool get isDebianLike =>
      _debianIds.contains(id) ||
      idLike.contains('debian') ||
      idLike.contains('ubuntu');

  /// Rule 2: RPM family (dnf/yum/zypper) — the name is historical. The
  /// family label exists so a future `backend.rpm` slice can branch on
  /// it; seeded defaults are identical for all of them today.
  bool get isFedoraLike =>
      !isDebianLike &&
      (_fedoraIds.contains(id) ||
          idLike.contains('fedora') ||
          idLike.contains('rhel') ||
          idLike.contains('suse') ||
          idLike.contains('opensuse'));

  /// Rule 3: Arch family.
  bool get isArchLike =>
      !isDebianLike &&
      !isFedoraLike &&
      (_archIds.contains(id) || idLike.contains('arch'));

  /// Rule 4: everything else, including parse failure.
  bool get isUnknown => !isDebianLike && !isFedoraLike && !isArchLike;
}

/// Reads `/etc/os-release` content. Production reads the file; tests
/// inject a path or raw content.
typedef OsReleaseReader = String? Function();

/// Production reader: the file, or `null` on any failure (missing,
/// unreadable, …).
String? _productionOsReleaseReader() {
  try {
    return File('/etc/os-release').readAsStringSync();
  } catch (_) {
    return null;
  }
}

String _unquote(String value) {
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

/// Parse the distro family. NEVER throws: unreadable file, missing
/// `ID=`, or garbage content all yield [PlatformInfo.unknown()].
PlatformInfo detectPlatform({OsReleaseReader? reader}) {
  try {
    final content = (reader ?? _productionOsReleaseReader)();
    if (content == null) return const PlatformInfo.unknown();
    var id = '';
    var idLike = const <String>[];
    var prettyName = '';
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final eq = trimmed.indexOf('=');
      if (eq < 0) continue;
      final key = trimmed.substring(0, eq).trim();
      final value = _unquote(trimmed.substring(eq + 1).trim());
      // First occurrence wins; IDs are lowercase by spec but the
      // parse is defensive anyway.
      switch (key) {
        case 'ID':
          if (id.isEmpty) id = value.toLowerCase();
        case 'ID_LIKE':
          if (idLike.isEmpty) {
            idLike = value
                .toLowerCase()
                .split(RegExp(r'\s+'))
                .where((s) => s.isNotEmpty)
                .toList();
          }
        case 'PRETTY_NAME':
          if (prettyName.isEmpty) prettyName = value;
      }
    }
    if (id.isEmpty) return const PlatformInfo.unknown();
    return PlatformInfo(id: id, idLike: idLike, prettyName: prettyName);
  } catch (_) {
    return const PlatformInfo.unknown();
  }
}

/// Apply the platform-detection.md §3 seed table: writes only the
/// seeded-defaults layer ([MapFeatureFlags.seedDefault]), so later
/// [MapFeatureFlags.setFlag] calls (user, Settings UI, tests) always
/// win. Pure function of (flags, platform) — no I/O.
///
/// - fedora-like / arch-like: `backend.snap.enabled=false`,
///   `backend.deb.enabled=false` (the honesty fix: an apt/dpkg backend
///   can never be honest on an rpm/pacman system; snapd is
///   Ubuntu-canonical).
/// - debian-like / unknown: seed nothing — the compiled defaults are
///   today's behavior, byte-identical.
void seedPlatformBackendDefaults(MapFeatureFlags flags, PlatformInfo platform) {
  if (platform.isFedoraLike || platform.isArchLike) {
    flags.seedDefault('backend.snap.enabled', false);
    flags.seedDefault('backend.deb.enabled', false);
  }
}
