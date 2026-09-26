/// [DebOperationHandle]: drives the contract's state machine by
/// consuming a PackageKit transaction's event stream.
///
/// PackageKit phases map onto operation states:
/// `download*` → [Downloading] (percentage, normalized to 0..100 bytes),
/// `install`/`remove`/`update` → [Applying], `signatureCheck` →
/// [Verifying]. Anything else in flight reads as [Preparing].
///
/// A transition the [legalTransitions] DAG forbids is never emitted —
/// the handle holds its current phase instead of lying.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'transport.dart';

class DebOperationHandle implements OperationHandle {
  DebOperationHandle({
    required this.app,
    required this.kind,
    required DebTransaction transaction,
    required StoreException Function(PackageKitTransportException e) mapError,
  }) : _transaction = transaction,
       _mapError = mapError,
       _current = const Queued(position: 0) {
    unawaited(_run());
  }

  /// Idempotent no-op: first state [Queued], then `Done(noop: true)`.
  DebOperationHandle.noop({required this.app, required this.kind})
    : _transaction = null,
      _mapError = ((e) =>
          UnknownStoreException(debugDetail: 'unreachable', backendId: 'deb')),
      _current = const Queued(position: 0) {
    unawaited(_runNoop());
  }

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  final DebTransaction? _transaction;
  final StoreException Function(PackageKitTransportException) _mapError;
  final _controller = StreamController<OperationState>.broadcast();
  OperationState _current;
  bool _cancelRequested = false;
  bool _closed = false;

  @override
  String get id => 'deb-${app.nativeId}-${kind.name}';

  @override
  Stream<OperationState> get state => _controller.stream;

  @override
  OperationState get current => _current;

  void _emit(OperationState s) {
    _current = s;
    if (!_closed) _controller.add(s);
  }

  /// Emit only DAG-legal transitions. Progress phases may update with
  /// new values; static phases never repeat (Preparing→Preparing is
  /// illegal). Anything else holds the current phase — never a lie.
  void _emitState(OperationState next) {
    if (next.runtimeType == _current.runtimeType) {
      if (next is Downloading) {
        final cur = _current;
        if (cur is Downloading && next.bytesDone != cur.bytesDone) {
          _emit(next);
        }
      }
      return;
    }
    final allowed = legalTransitions[_current.runtimeType];
    if (allowed != null && allowed.contains(next.runtimeType)) {
      _emit(next);
    }
  }

  Future<void> _close() async {
    _closed = true;
    await _controller.close();
  }

  Future<void> _runNoop() async {
    await Future<void>.delayed(Duration.zero);
    _emit(const Done(result: OperationResult(noop: true)));
    await _close();
  }

  Future<void> _run() async {
    // Let the constructor finish so the first observed state is Queued.
    await Future<void>.delayed(Duration.zero);
    final transaction = _transaction!;
    if (_cancelRequested) {
      await _abort();
      return;
    }
    _emit(const Preparing());
    var terminated = false;
    try {
      await for (final event in transaction.events) {
        if (event is DebTxProgress) {
          _emitState(_phaseFor(event));
        } else if (event is DebTxDone) {
          _resolveTerminal(event);
          terminated = true;
          break;
        }
      }
    } catch (e) {
      _emit(
        Failed(
          error: _mapError(
            PackageKitTransportException('transaction stream failed: $e'),
          ),
        ),
      );
      terminated = true;
    }
    if (!terminated) {
      // The stream ended without a terminal event — never hang the UI.
      _emit(
        Failed(
          error: _mapError(
            PackageKitTransportException(
              'transaction ended without a terminal event',
            ),
          ),
        ),
      );
    }
    await _close();
  }

  /// PackageKit reports 0..100 percent; the contract wants bytes, so
  /// the percentage is normalized onto a 0..100 byte scale. Monotonic
  /// and bounded — never a fabricated byte count.
  OperationState _phaseFor(DebTxProgress progress) {
    switch (progress.status) {
      case DebTxStatus.download:
        return Downloading(bytesDone: progress.percentage, bytesTotal: 100);
      case DebTxStatus.install:
      case DebTxStatus.remove:
      case DebTxStatus.update:
        return const Applying();
      case DebTxStatus.verifying:
        return const Verifying();
      case DebTxStatus.unknown:
      case DebTxStatus.other:
        return const Preparing();
    }
  }

  void _resolveTerminal(DebTxDone done) {
    switch (done.outcome) {
      case DebTxOutcome.success:
        // Only Applying→Done is legal: bridge through Applying first.
        _emitState(const Applying());
        _emit(Done(result: OperationResult(cancelRequested: _cancelRequested)));
      case DebTxOutcome.cancelled:
        _emitState(const Cancelling());
        _emit(const Cancelled());
      case DebTxOutcome.failed:
        if (_cancelRequested) {
          // We asked for it; the failure is the cancel racing the daemon.
          _emitState(const Cancelling());
          _emit(const Cancelled());
        } else {
          final detail = [
            if (done.errorCode.isNotEmpty) done.errorCode,
            if (done.errorDetails.isNotEmpty) done.errorDetails,
          ].join(': ');
          _emit(
            Failed(
              error: _mapError(
                PackageKitTransportException(
                  detail.isEmpty ? 'packagekit transaction failed' : detail,
                ),
              ),
            ),
          );
        }
    }
  }

  Future<void> _abort() async {
    _emitState(const Cancelling());
    _emit(const Cancelled());
    await _close();
  }

  @override
  Future<void> cancel() async {
    if (_current.isTerminal || _closed) return;
    _cancelRequested = true;
    // Best effort: the Finished event still flows through the stream,
    // which resolves the honest outcome.
    try {
      await _transaction?.cancel();
    } catch (_) {}
  }
}
