/// The operation state machine — the product's heart (ADR-008).
///
/// One install/update/remove = one handle = one state machine.
/// The UI binds to this and nothing else. Full contract:
/// `docs/architecture/operation-state-machine.md`.
///
/// Notes on the Dart shape:
/// - Sealed class hierarchy, no codegen, zero dependencies.
/// - `Stream<OperationState> get state` + `OperationState get current`
///   (the LLD sketch said `ValueStream`; a plain stream plus a current
///   getter keeps the law rxdart-free).
library;

import 'errors.dart';
import 'identity.dart';

enum OperationKind { install, remove, update }

/// Payload of the [Done] state.
class OperationResult {
  const OperationResult({
    this.installedVersion,
    this.requiresRestart = false,
    this.noop = false,
    this.cancelRequested = false,
  });

  /// Version now on the system, if known.
  final String? installedVersion;

  /// E.g. kernel/driver updates.
  final bool requiresRestart;

  /// Already in the desired state — nothing changed, nothing downloaded.
  final bool noop;

  /// User asked to cancel but the op was past the point of no return
  /// and completed anyway. The UI says so honestly.
  final bool cancelRequested;
}

sealed class OperationState {
  const OperationState();

  bool get isTerminal => this is Done || this is Cancelled || this is Failed;
}

/// Waiting for an engine slot. [position] 0 = next to run.
final class Queued extends OperationState {
  const Queued({required this.position});
  final int position;
}

/// Re-attached after app restart to an op the backend reports still
/// running. Emitted once, then normal phases resume.
final class Restoring extends OperationState {
  const Restoring();
}

/// Privilege prompt (polkit) in flight.
final class Authenticating extends OperationState {
  const Authenticating();
}

/// Dependency resolution, disk-space preflight, sanity checks.
final class Preparing extends OperationState {
  const Preparing();
}

/// Fetching payload. [bytesTotal] null = size unknown → indeterminate UI.
final class Downloading extends OperationState {
  const Downloading({required this.bytesDone, this.bytesTotal});
  final int bytesDone;
  final int? bytesTotal;
}

/// Checksum/signature verification. Optional — backends may skip it.
final class Verifying extends OperationState {
  const Verifying();
}

/// Mutating the system (linking, unpacking, removing).
/// [fraction] null = indeterminate. Named `applying`, not `installing`,
/// so it reads honestly for remove/update too.
final class Applying extends OperationState {
  const Applying({this.fraction});
  final double? fraction;
}

/// Cancel requested, backend winding down. Transitional — the UI shows
/// "Cancelling…" instead of pretending work continues.
final class Cancelling extends OperationState {
  const Cancelling();
}

final class Done extends OperationState {
  const Done({required this.result});
  final OperationResult result;
}

/// INVARIANT: the system is unchanged — the backend cleaned up
/// partial work (downloads removed, locks released).
final class Cancelled extends OperationState {
  const Cancelled();
}

final class Failed extends OperationState {
  const Failed({required this.error});
  final StoreException error;
}

abstract class OperationHandle {
  /// Unique per operation.
  String get id;

  AppIdentity get app;

  OperationKind get kind;

  /// Current state + updates. Terminal states emit no further events.
  Stream<OperationState> get state;

  /// Latest state, synchronously.
  OperationState get current;

  /// Request cancellation. Safe in any state; no-op when terminal.
  /// The backend MUST reach a terminal state within 2s, and MUST NOT
  /// convert a user cancel into a bare [Failed].
  Future<void> cancel();
}

/// The legal transition DAG (operation-state-machine.md §2), as data —
/// the contract exam validates recorded transitions against this.
///
/// Phases may be skipped forward freely; a phase is never re-entered.
const Map<Type, Set<Type>> legalTransitions = {
  Queued: {Authenticating, Preparing, Downloading, Verifying, Applying, Cancelling, Failed},
  Restoring: {Authenticating, Preparing, Downloading, Verifying, Applying, Cancelling, Failed},
  Authenticating: {Preparing, Downloading, Verifying, Applying, Cancelling, Failed},
  Preparing: {Authenticating, Downloading, Verifying, Applying, Cancelling, Failed},
  Downloading: {Downloading, Verifying, Applying, Cancelling, Failed},
  Verifying: {Applying, Cancelling, Failed},
  Applying: {Applying, Cancelling, Done, Failed},
  Cancelling: {Cancelled, Done, Failed},
  Done: {},
  Cancelled: {},
  Failed: {},
};
