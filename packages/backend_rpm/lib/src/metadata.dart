/// RPM metadata presentation: version display and summary fallbacks.
///
/// The EVR is opaque — shown verbatim, never split into
/// epoch/version/release and never "prettified".
library;

/// The version string the UI shows: the EVR verbatim, or null when the
/// daemon emitted none. Never invents a version.
String? displayVersion(String evr) => evr.isEmpty ? null : evr;
