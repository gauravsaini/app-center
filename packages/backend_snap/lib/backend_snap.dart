/// `backend_snap` — the snap backend.
///
/// Talks to snapd over its change API (`/v2/changes`): installs return a
/// change id, and the operation handle polls the change, mapping snapd
/// task progress onto the contract's operation states. Everything
/// snapd-shaped goes through [SnapdTransport]; tests script a stub.
library backend_snap;

export 'package:store_contracts/store_contracts.dart';
export 'src/backend.dart';
export 'src/handle.dart';
export 'src/transport.dart';
