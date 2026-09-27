/// `backend_deb` — the deb backend.
///
/// Talks to PackageKit over D-Bus: mutating calls run on a dedicated
/// transaction whose progress events the operation handle maps onto the
/// contract's state machine. Everything PackageKit-shaped goes through
/// [PackageKitTransport]; tests script a stub.
library backend_deb;

export 'package:store_contracts/store_contracts.dart';
export 'src/backend.dart';
export 'src/handle.dart';
export 'src/packagekit_transport.dart';
export 'src/transport.dart';
