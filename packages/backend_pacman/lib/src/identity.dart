/// pacman identity helpers: package-id parsing, the name card key,
/// and display helpers.
///
/// The backend treats the native id as opaque above the transport
/// layer; only the transport parses it (for name/target at mutate
/// time). The version is never prettified — epoch prefixes make
/// prettifying lossy (research §3).
library;

import 'transport.dart';

/// Parse [raw] into a [PacmanPackageId]; throws [FormatException]
/// unless exactly 4 tokens with a non-empty name.
PacmanPackageId parsePackageId(String raw) => PacmanPackageId.parse(raw);

/// The UI card key: the package name alone. alpm's local db is
/// name-keyed, so one name is one card — deliberately unlike rpm's
/// (name, arch) cards (research §3).
String cardKeyFor(String name) => name;

/// Card subtitle: the bare name. Kept as a helper so a future
/// disambiguation need (there is none today) has one place to land.
String displaySubtitle(String name) => name;
