/// Stall advisory for the engine watchdog
/// (`docs/architecture/stall-watchdog.md`).
///
/// A side interface, not a state-machine state: the DAG in
/// `operation-state-machine.md` is untouched. Implemented by the engine's
/// handle wrapper (`StoreHost`); backends never implement this.
library;

/// Advisory stall flag on an [OperationHandle].
///
/// Set when the engine's watchdog fires (no state event for
/// `engine.stall_timeout` in a watched phase). The engine calls
/// `cancel()` at the same moment, so `isStalled` normally coincides with
/// the backend winding down — it stays visible when the backend never
/// acknowledges (no `cancelling` event arrives), instead of leaving the
/// UI frozen on a dead progress bar.
abstract class StallAware {
  /// Whether the watchdog has fired for this operation.
  bool get isStalled;

  /// Fires when [isStalled] changes (false → true only; never resets).
  Stream<bool> get stalledChanges;
}
