/// `backend_appimage` — the AppImage backend (ADR-006).
///
/// File-based transport: no daemon, no registry. Identity is the file's
/// sha256 (content-addressed). Everything the backend needs from the
/// outside world goes through [AppImageTransport], so tests script a
/// stub and never touch the live system.
///
/// ```dart
/// final backend = BackendAppimage(transport: RealAppImageTransport());
/// await runContractExam('appimage', () => backend, ...);
/// ```
library backend_appimage;

export 'src/backend.dart';
export 'src/identity.dart';
export 'src/metadata.dart';
