/// `store_contracts` — the law (ADR-002).
///
/// Stable, versioned interfaces every backend implements and the host
/// consumes. Zero dependencies. See `docs/architecture/lld.md` and
/// `docs/architecture/operation-state-machine.md`.
library store_contracts;

export 'src/backend.dart';
export 'src/catalog.dart';
export 'src/engine.dart';
export 'src/errors.dart';
export 'src/flags.dart';
export 'src/heartbeat.dart';
export 'src/identity.dart';
export 'src/operation.dart';
export 'src/stall.dart';
export 'src/version.dart';
