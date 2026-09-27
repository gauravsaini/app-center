/// [StoreBackend] — the plugin interface every backend implements.
library;

import 'errors.dart';
import 'identity.dart';
import 'operation.dart';

/// What a backend can do. The host adapts UI to the advertised set;
/// calling an unadvertised method is a contract violation.
enum BackendCapability {
  search,
  details,
  install,
  remove,
  update,
  permissions,
  ratings,
}

/// One available update, as reported by a backend.
class UpdateInfo {
  const UpdateInfo({
    required this.identity,
    required this.name,
    this.fromVersion,
    this.toVersion,
    this.sizeBytes,
  });

  final AppIdentity identity;
  final String name;
  final String? fromVersion;
  final String? toVersion;
  final int? sizeBytes;
}

abstract class StoreBackend {
  /// Stable id: 'snap', 'deb', 'flatpak', …
  String get id;

  /// Major version of `store_contracts` this backend implements.
  /// The host refuses to load mismatched majors.
  int get contractVersion;

  Set<BackendCapability> get capabilities;

  /// Is the backend usable right now? MUST complete in <200ms,
  /// have no side effects, and be safe to call twice.
  /// A missing backend is normal, not an application failure (ADR-010).
  Future<bool> isAvailable();

  /// Fan-out search over this backend. The returned stream MUST be
  /// cancellable: cancelling the subscription stops backend work
  /// within 500ms (no orphaned processes).
  /// PRE: query is 1..200 chars.
  Stream<AppInfo> search(String query);

  /// Full details for the app page.
  /// PRE: capabilities contains [BackendCapability.details].
  /// THROWS: [AppNotFoundException] for unknown ids — never a raw crash.
  Future<AppDetails> getDetails(AppIdentity id);

  /// Begin install. Returns immediately with a handle; progress flows
  /// through the handle's state machine.
  /// PRE: capabilities contains [BackendCapability.install].
  /// Idempotent: installing an installed app → `Done(noop: true)`.
  Future<OperationHandle> install(AppIdentity id);

  /// Begin remove. Same handle discipline as install.
  /// PRE: capabilities contains [BackendCapability.remove].
  Future<OperationHandle> remove(AppIdentity id);

  /// Begin update of an installed app.
  /// PRE: capabilities contains [BackendCapability.update].
  Future<OperationHandle> update(AppIdentity id);

  /// Available updates known to this backend.
  Future<List<UpdateInfo>> checkUpdates();

  /// Installed apps managed by this backend.
  ///
  /// PRE: none. A backend that cannot enumerate its installed apps
  ///   returns [] (the default) — "not supported".
  /// POST: every returned [AppInfo.identity.backendId] == this backend's
  ///   `id`. Identities carrying another backend's id are a contract
  ///   violation (exam-enforced).
  /// THROWS: [StoreException] subtypes only — never raw errors. A raw
  ///   throw fails the contract exam (the host catches regardless).
  ///
  /// The default implementation returns []. Backends inherit it and keep
  /// compiling — this is the LLD §10 additive path (new optional method
  /// with a default, minor version bump).
  Future<List<AppInfo>> listInstalled() => Future.value(const []);

  /// Best-effort re-attach to operations the backend reports still
  /// running after an app restart. Re-attached handles start with
  /// the [Restoring] state. Backends that can't do this return [].
  Future<List<OperationHandle>> recoverInFlight();

  /// Contract rules (enforced by the exam):
  /// - No blocking the UI thread. All I/O async; heavy parsing off
  ///   the main isolate.
  /// - Backends MUST NOT show their own dialogs. Auth/errors surface
  ///   through [OperationHandle] and [StoreException]; the host renders.
  /// - Backends MUST NOT write outside their domain.
  /// - All thrown errors are [StoreException] subtypes.
}
