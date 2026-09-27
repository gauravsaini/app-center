/// [PacmanOperationHandle]: drives the contract's state machine by
/// consuming a pkexec'd pacman child's line-classified event stream.
///
/// Phase mapping (research §2.7, LLD §5):
/// - spawn, no output yet (polkit prompt in flight) → [Authenticating]
/// - `resolving dependencies…`, `Packages (N)…`, `Total … Size:` →
///   [Preparing] (`Total Download Size:` also latches `bytesTotal`)
/// - `:: Retrieving packages…`, `<file> downloading…` → [Downloading]
///   (`bytesDone` stays 0 — piped pacman prints no byte-true progress,
///   research §2.8; the phase + heartbeat are the honest signal)
/// - `checking keyring…` / `checking package integrity…` → [Verifying]
/// - `(N/M) installing|upgrading|removing …`,
///   `:: Processing package changes…`,
///   `:: Running post-transaction hooks…` → [Applying] (real,
///   monotonic `N/M` fraction when markers are seen)
///
/// pkexec exit 126 → the user dismissed the auth dialog →
/// `Failed(AuthException(dismissed))`, quiet. Exit 127 → not
/// authorized → `Failed(PermissionException)`.
///
/// A transition the [legalTransitions] DAG forbids is never emitted —
/// the handle holds its current phase instead of lying.
///
/// NON-ATOMICITY (research §8): killing pacman mid-apply is NOT
/// transactional — SIGKILL during apply can leave a half-configured
/// system (the next `pacman -Su` repairs it). The handle reports
/// [Cancelled] — the user's request was honored, the process is dead
/// — and must NOT report [Done]. Do not "fix" this into a lie.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'transport.dart';

class PacmanOperationHandle implements OperationHandle {
  PacmanOperationHandle({
    required this.app,
    required this.kind,
    required PacmanTransaction transaction,
    required StoreException Function(PacmanTransportException e) mapError,
    Duration heartbeatInterval = const Duration(seconds: 60),
  }) : _transaction = transaction,
       _mapError = mapError,
       _heartbeat = PhaseHeartbeat(interval: heartbeatInterval),
       _current = const Queued(position: 0) {
    unawaited(_run());
  }

  /// Idempotent no-op: first state [Queued], then `Done(noop: true)`.
  PacmanOperationHandle.noop({required this.app, required this.kind})
    : _transaction = null,
      _mapError = ((e) => UnknownStoreException(
        debugDetail: 'unreachable',
        backendId: 'pacman',
      )),
      _heartbeat = PhaseHeartbeat(),
      _current = const Queued(position: 0) {
    unawaited(_runNoop());
  }

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  final PacmanTransaction? _transaction;
  final StoreException Function(PacmanTransportException) _mapError;

  /// Stall-watchdog heartbeat (`docs/architecture/stall-watchdog.md` §1):
  /// re-emits a silent downloading/applying phase at least every
  /// [PhaseHeartbeat.interval] so the engine sees liveness. The timer is
  /// best-effort — its body is guarded and it can never break the
  /// operation.
  final PhaseHeartbeat _heartbeat;
  Timer? _heartbeatTimer;
  final _controller = StreamController<OperationState>.broadcast();
  OperationState _current;
  bool _cancelRequested = false;
  bool _closed = false;

  @override
  String get id => 'pacman-${app.nativeId}-${kind.name}';

  @override
  Stream<OperationState> get state => _controller.stream;

  @override
  OperationState get current => _current;

  void _emit(OperationState s) {
    _current = s;
    _heartbeat.markEmitted();
    if (s is Downloading || s is Applying) {
      _startHeartbeat();
    } else {
      _stopHeartbeat();
    }
    if (!_closed) _controller.add(s);
  }

  /// Start the periodic heartbeat on the first downloading/applying
  /// emission; idempotent — later emissions in the same phase re-use it.
  void _startHeartbeat() {
    _heartbeatTimer ??= Timer.periodic(_heartbeat.interval, (_) {
      try {
        // The identical state object is a legal self-transition
        // (Downloading→Downloading, Applying→Applying per the DAG).
        if (_heartbeat.shouldBeat(_current)) _emit(_current);
      } catch (_) {
        // Best-effort: the heartbeat must never break the operation.
      }
    });
  }

  /// Cancel the heartbeat on phase change and terminal states.
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Emit only DAG-legal transitions. Progress phases may update with
  /// new values; static phases never repeat. A liveness pulse (same
  /// phase, same values) only marks the heartbeat — no visible noise.
  /// Anything else holds the current phase — never a lie.
  void _emitState(OperationState next) {
    if (next.runtimeType == _current.runtimeType) {
      final cur = _current;
      final changed =
          (next is Downloading &&
              cur is Downloading &&
              (next.bytesDone != cur.bytesDone ||
                  next.bytesTotal != cur.bytesTotal)) ||
          (next is Applying &&
              cur is Applying &&
              next.fraction != cur.fraction);
      if (changed) _emit(next);
      // Identical: liveness only. (markEmitted is also called by
      // _emit, so this line only matters for the held path.)
      _heartbeat.markEmitted();
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
    // The polkit prompt is in flight between spawn and the first
    // pacman stdout line — the authenticating phase is real
    // (research §4).
    _emit(const Authenticating());
    var terminated = false;
    try {
      await for (final event in transaction.events) {
        if (event is PacmanTxProgress) {
          _emitState(_stateFor(event));
        } else if (event is PacmanTxDone) {
          _resolveTerminal(event);
          terminated = true;
          break;
        }
      }
    } catch (e) {
      _emit(
        Failed(
          error: _mapError(
            PacmanTransportException(
              ['pacman'],
              -1,
              'transaction stream failed: $e',
            ),
          ),
        ),
      );
      terminated = true;
    }
    if (!terminated) {
      // The stream ended without a terminal event — never hang the UI.
      // If we asked for a cancel, the honest reading is that the kill
      // landed and the transport had nothing more to say: Cancelled,
      // not Failed.
      if (_cancelRequested) {
        _emit(const Cancelled());
      } else {
        _emit(
          Failed(
            error: _mapError(
              PacmanTransportException(
                ['pacman'],
                -1,
                'transaction ended without a terminal event',
              ),
            ),
          ),
        );
      }
    }
    await _close();
  }

  /// Progress event → operation state. `bytesDone` stays 0 through
  /// download: piped pacman prints no byte-true progress, so the
  /// download is honestly indeterminate (research §2.8) — the phase
  /// and the 60s heartbeat are the liveness signal, not a fabricated
  /// bar.
  OperationState _stateFor(PacmanTxProgress p) => switch (p.phase) {
    PacmanTxPhase.authenticating => const Authenticating(),
    PacmanTxPhase.preparing => const Preparing(),
    PacmanTxPhase.downloading => Downloading(
      bytesDone: 0,
      bytesTotal: p.bytesTotal,
    ),
    PacmanTxPhase.verifying => const Verifying(),
    PacmanTxPhase.applying => Applying(fraction: p.fraction),
  };

  void _resolveTerminal(PacmanTxDone done) {
    // Cancel-then-fail races resolve to Cancelled, never Failed
    // (operation-state-machine.md §3): if the child died from our
    // signal, the user's cancel wins even if pacman printed errors
    // while dying.
    final cancelledByUs = done.cancelledByUs || _cancelRequested;
    if (cancelledByUs) {
      if (done.exitCode == 0) {
        // pacman committed before the signal landed — pacman does not
        // roll back (research §8). Honest: done, cancel requested.
        _emitState(const Done(result: OperationResult(cancelRequested: true)));
      } else {
        _emitState(const Cancelling());
        _emit(const Cancelled());
      }
      return;
    }
    switch (done.exitCode) {
      case 0:
        // Only Applying→Done is legal: bridge through Applying first.
        _emitState(const Applying());
        _emit(Done(result: OperationResult(cancelRequested: _cancelRequested)));
      case 126:
        // The user dismissed the polkit dialog — quiet, never nag
        // (operation-state-machine.md §7).
        _emit(
          const Failed(
            error: AuthException(
              debugDetail: 'polkit dialog dismissed',
              kind: AuthKind.dismissed,
              backendId: 'pacman',
            ),
          ),
        );
      case 127:
        _emit(Failed(error: _polkitDenied(done.stderr)));
      default:
        _emit(
          Failed(
            error: _mapError(
              PacmanTransportException(
                ['pkexec', 'pacman'],
                done.exitCode,
                done.stderr,
              ),
            ),
          ),
        );
    }
  }

  /// pkexec exit 127: not authorized / auth error / pkexec-level
  /// failure (research §4). A missing pkexec binary carries the
  /// polkit-install remediation; a denied auth names the access.
  StoreException _polkitDenied(String stderr) {
    if (stderr.contains('pkexec not found')) {
      return PermissionException(
        debugDetail: stderr,
        neededAccess:
            'polkit (pkexec) for privileged pacman operations — install '
            'polkit and use a session with an authentication agent',
        backendId: 'pacman',
      );
    }
    return PermissionException(
      debugDetail: stderr,
      neededAccess: 'polkit authorization for pacman',
      backendId: 'pacman',
    );
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
    // Prompt ack: the contract requires Cancelling within 2s
    // (operation-state-machine.md §3) — emit it now, then kill the
    // child. The terminal state follows the child's exit via the
    // event stream (_resolveTerminal).
    _emitState(const Cancelling());
    try {
      await _transaction?.cancel();
    } catch (_) {}
  }
}
