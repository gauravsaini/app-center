/// [AppimageOperationHandle]: drives the install/remove state machine for
/// file-copy operations.
///
/// The backend emits phase states through [emit] and observes
/// cancellation via [throwIfCancelled].
/// Cancellation always lands on [Cancelled] after best-effort cleanup —
/// never a bare [Failed]. Follows the legal transition DAG in
/// `store_contracts/lib/src/operation.dart`.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

/// Thrown by [AppimageOperationHandle.throwIfCancelled]; the backend
/// catches it to roll back partial work, then rethrows so the handle
/// lands on [Cancelled].
class AppimageOperationCancelled implements Exception {
  const AppimageOperationCancelled();
}

class AppimageOperationHandle implements OperationHandle {
  AppimageOperationHandle._({required this.app, required this.kind})
    : _current = const Queued(position: 0);

  /// Run [body]: it emits its own phase states via [emit] and returns
  /// the terminal [OperationResult]. Throws map to terminal states:
  /// [AppimageOperationCancelled] → [Cancelled], [StoreException] →
  /// [Failed], anything else → [Failed] with [UnknownStoreException]
  /// (raw errors never escape).
  static AppimageOperationHandle run({
    required AppIdentity app,
    required OperationKind kind,
    required Future<OperationResult> Function(AppimageOperationHandle handle)
    body,
  }) {
    final handle = AppimageOperationHandle._(app: app, kind: kind);
    unawaited(handle._execute(body));
    return handle;
  }

  /// The honest no-op: `Queued → Done(noop: true)` — no work, no download.
  /// The exam special-cases exactly this transition.
  static AppimageOperationHandle noop({
    required AppIdentity app,
    required OperationKind kind,
  }) {
    final handle = AppimageOperationHandle._(app: app, kind: kind);
    unawaited(handle._execute((_) async => const OperationResult(noop: true)));
    return handle;
  }

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  @override
  String get id => 'appimage-${app.nativeId}-${kind.name}';

  final _controller = StreamController<OperationState>.broadcast();
  OperationState _current;
  bool _closed = false;
  bool _cancelRequested = false;

  @override
  Stream<OperationState> get state => _controller.stream;

  @override
  OperationState get current => _current;

  /// Backend phases call this. Emits are ignored once terminal, and a
  /// [Cancelling] handle only accepts terminal states (the body must
  /// [throwIfCancelled] instead of advancing phases).
  void emit(OperationState state) {
    if (_closed || _current.isTerminal) return;
    if (_current is Cancelling && !state.isTerminal) return;
    _current = state;
    _controller.add(state);
  }

  /// Throws [AppimageOperationCancelled] when [cancel] was requested.
  void throwIfCancelled() {
    if (_cancelRequested) throw const AppimageOperationCancelled();
  }

  Future<void> _execute(
    Future<OperationResult> Function(AppimageOperationHandle) body,
  ) async {
    // Let the constructor finish so the first observed state is Queued.
    await Future<void>.delayed(Duration.zero);
    try {
      final result = await body(this);
      emit(Done(result: result));
    } on AppimageOperationCancelled {
      emit(const Cancelled());
    } on StoreException catch (e) {
      // A cancel racing a failure is still a cancel.
      emit(_cancelRequested ? const Cancelled() : Failed(error: e));
    } catch (e) {
      emit(
        _cancelRequested
            ? const Cancelled()
            : Failed(
                error: UnknownStoreException(
                  debugDetail: 'appimage operation failed: $e',
                  backendId: 'appimage',
                ),
              ),
      );
    } finally {
      _closed = true;
      await _controller.close();
    }
  }

  @override
  Future<void> cancel() async {
    if (_current.isTerminal || _closed || _cancelRequested) return;
    _cancelRequested = true;
    emit(const Cancelling());
    // The body observes the flag via throwIfCancelled() and drives
    // Cancelling → Cancelled (after deleting partial work) within the
    // 2s spec budget.
  }
}
