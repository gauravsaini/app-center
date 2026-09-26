/// [SnapOperationHandle]: drives the contract's state machine by polling
/// a snapd change.
///
/// snapd task kinds map onto operation phases:
/// `download-snap` → [Downloading] (with real byte progress),
/// `validate-snap` → [Verifying], `mount/link/setup/connect-snap` →
/// [Applying]. Anything else in flight reads as [Preparing].
///
/// A transition the [legalTransitions] DAG forbids is never emitted —
/// the handle holds its current phase instead of lying.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'transport.dart';

class SnapOperationHandle implements OperationHandle {
  SnapOperationHandle({
    required this.app,
    required this.kind,
    required SnapdTransport transport,
    required String changeId,
    required StoreException Function(SnapdTransportException e) mapError,
    Duration pollInterval = const Duration(milliseconds: 500),
  }) : _transport = transport,
       _changeId = changeId,
       _mapError = mapError,
       _pollInterval = pollInterval,
       _current = const Queued(position: 0) {
    unawaited(_run());
  }

  /// Idempotent no-op: first state [Queued], then `Done(noop: true)`.
  SnapOperationHandle.noop({required this.app, required this.kind})
    : _transport = null,
      _changeId = '',
      _mapError = ((e) =>
          UnknownStoreException(debugDetail: 'unreachable', backendId: 'snap')),
      _pollInterval = Duration.zero,
      _current = const Queued(position: 0) {
    unawaited(_runNoop());
  }

  /// Re-attach to a change that outlived the app process.
  /// First observed state is [Restoring], per the contract.
  SnapOperationHandle.attached({
    required this.app,
    required this.kind,
    required SnapdTransport transport,
    required String changeId,
    required StoreException Function(SnapdTransportException e) mapError,
    Duration pollInterval = const Duration(milliseconds: 500),
  }) : _transport = transport,
       _changeId = changeId,
       _mapError = mapError,
       _pollInterval = pollInterval,
       _current = const Restoring() {
    unawaited(_run());
  }

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  final SnapdTransport? _transport;
  final String _changeId;
  final StoreException Function(SnapdTransportException) _mapError;
  final Duration _pollInterval;
  final _controller = StreamController<OperationState>.broadcast();
  OperationState _current;
  bool _cancelRequested = false;
  bool _closed = false;

  @override
  String get id => 'snap-${app.nativeId}-${kind.name}';

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
    // Let the constructor finish so the first observed state is
    // Queued (or Restoring for re-attached handles).
    await Future<void>.delayed(Duration.zero);
    final transport = _transport!;
    if (_cancelRequested) {
      await _abort(transport);
      return;
    }
    if (_current is Queued) _emit(const Preparing());

    while (true) {
      late final SnapdChangeSnapshot change;
      try {
        change = await transport.getChange(_changeId);
      } catch (e) {
        _emit(
          Failed(
            error: _mapError(SnapdTransportException('getChange failed: $e')),
          ),
        );
        break;
      }
      if (change.ready && change.status == 'Done') {
        _emitState(const Applying());
        _emit(Done(result: OperationResult(cancelRequested: _cancelRequested)));
        break;
      }
      if (change.status == 'Error') {
        if (_cancelRequested) {
          await _abort(transport);
        } else {
          _emit(
            Failed(
              error: _mapError(
                SnapdTransportException(
                  change.error.isEmpty ? 'snapd change failed' : change.error,
                ),
              ),
            ),
          );
        }
        break;
      }
      _emitState(_phaseFor(change));
      await Future<void>.delayed(_pollInterval);
    }
    await _close();
  }

  OperationState _phaseFor(SnapdChangeSnapshot change) {
    if (change.status == 'Doing') {
      for (final t in change.tasks) {
        if (t.status != 'Doing') continue;
        final k = t.kind.toLowerCase();
        if (k.contains('download')) {
          return Downloading(
            bytesDone: t.done,
            bytesTotal: t.total == 0 ? null : t.total,
          );
        }
        if (k.contains('validate')) return const Verifying();
        if (k.contains('mount') ||
            k.contains('link') ||
            k.contains('setup') ||
            k.contains('connect') ||
            k.contains('start')) {
          return const Applying();
        }
      }
    }
    return const Preparing();
  }

  Future<void> _abort(SnapdTransport transport) async {
    _emitState(const Cancelling());
    _emit(const Cancelled());
    await _close();
  }

  @override
  Future<void> cancel() async {
    if (_current.isTerminal || _closed) return;
    _cancelRequested = true;
    // Best effort: aborting an already-finished change errors, which
    // is fine — the poll loop resolves the honest outcome.
    try {
      await _transport?.abortChange(_changeId);
    } catch (_) {}
  }
}
