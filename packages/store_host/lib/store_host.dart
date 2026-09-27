/// `store_host` — host-side orchestration.
///
/// The host owns the catalog, the operations, the flags, and the
/// policy. Backends are plugins registered at the composition root
/// (the app's `main.dart`); UI pages import only this package and
/// `store_contracts` — never `backend_*`.
library store_host;

export 'package:store_contracts/store_contracts.dart';
export 'src/check_updates_result.dart';
export 'src/flags.dart';
export 'src/host.dart';
export 'src/identity/community_refresh.dart';
export 'src/identity/community_transport.dart';
export 'src/identity/identity_resolver.dart';
export 'src/installed_result.dart';
export 'src/platform_detection.dart';
