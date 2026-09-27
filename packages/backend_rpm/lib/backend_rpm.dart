/// `backend_rpm` — the RPM backend (PackageKit/D-Bus, dnf5).
///
/// Identity is the daemon's verbatim 5-token package-id
/// (`name;evr;arch;origin;data`); cards are keyed (name, arch) so
/// multi-arch packages stay separate. Everything the backend needs
/// from the outside world goes through [RpmTransport], so tests script
/// a stub and never touch D-Bus.
///
/// ```dart
/// final backend = BackendRpm(transport: RealRpmPackageKitTransport());
/// await runContractExam('rpm', () => backend, ...);
/// ```
library backend_rpm;

export 'src/backend.dart';
export 'src/identity.dart';
