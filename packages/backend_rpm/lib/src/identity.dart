/// RPM identity helpers: package-id parsing, the (name, arch) card key,
/// and display helpers.
///
/// The backend treats the native id as opaque above the transport
/// layer; only the transport parses it (for name/arch at mutate time).
/// The EVR is never prettified — epoch-0 omission makes prettifying
/// lossy (research §1.2).
library;

import 'transport.dart';

/// Parse [raw] into a [RpmPackageId]; throws [FormatException] unless
/// exactly 5 tokens.
RpmPackageId parsePackageId(String raw) => RpmPackageId.parse(raw);

/// The UI card key: multi-arch packages are separate cards
/// (`firefox.x86_64` vs `firefox.i686`).
String cardKeyFor(String name, String arch) => '$name.$arch';

/// Card subtitle: the bare name, or `name · arch` when a sibling arch
/// of the same name exists — the (name, arch) disambiguation the card
/// key implies (HLD §4).
String displaySubtitle(
  String name,
  String arch, {
  required bool hasSiblingArch,
}) => hasSiblingArch ? '$name · $arch' : name;
