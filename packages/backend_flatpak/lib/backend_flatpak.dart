/// `backend_flatpak` — the Flatpak backend (ADR-006).
///
/// CLI-wrapper transport: talks to the `flatpak(1)` binary, never to
/// libflatpak directly. Everything the backend needs from the outside
/// world goes through [FlatpakTransport], so tests script a stub and
/// never touch the live system.
///
/// ```dart
/// final backend = BackendFlatpak(transport: CliFlatpakTransport());
/// await runContractExam('flatpak', () => backend, ...);
/// ```
library backend_flatpak;

export 'package:store_contracts/store_contracts.dart';
export 'src/backend.dart';
export 'src/handle.dart';
export 'src/progress.dart';
export 'src/ref.dart';
export 'src/transport.dart';
