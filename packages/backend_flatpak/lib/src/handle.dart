/// Drives an [OperationHandle] state machine from a spawned flatpak
/// process. Progress lines map to [Downloading]; exit 0 to [Done];
/// non-zero exit to a mapped [Failed]; [cancel] terminates the process
/// and lands on [Cancelled] (or an honest `Done(cancelRequested: true)`
/// when the process already finished).
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'progress.dart';
import 'transport.dart';

class FlatpakOperationHandle implements OperationHandle {
  FlatpakOperationHandle({
    required this.app,
    required this.kind,
    required FlatpakProcess process,
    required StoreException Function(FlatpakCommandException e) mapError,
    Duration heartbeatInterval = const Duration(seconds: 60),
  }) : _process = process,
       _mapError = mapError,
       _heartbeat = PhaseHeartbeat(interval: heartbeatInterval),
       _current = const Queued(position: 0) {
    unawaited(_run());
  }

  /// Handle for the idempotent no-op (already in the desired state).
  /// First state is [Queued]; the stream then emits `Done(noop: true)`
  /// with no download and no process spawned.
  FlatpakOperationHandle.noop({required this.app, required this.kind})
    : _process = null,
      _mapError = ((e) => UnknownStoreException(
        debugDetail: 'unreachable',
        backendId: 'flatpak',
      )),
      _heartbeat = PhaseHeartbeat(),
      _current = const Queued(position: 0) {
    unawaited(_runNoop());
  }

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  final FlatpakProcess? _process;
  final StoreException Function(FlatpakCommandException) _mapError;

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
  String get id => 'flatpak-${app.nativeId}-${kind.name}';

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
    final proc = _process!;
    if (_cancelRequested) {
      await _abort(proc);
      return;
    }
    _emit(const Preparing());

    final stderrBuf = StringBuffer();
    final stderrSub = proc.stderrLines.listen(stderrBuf.writeln);
    var sawProgress = false;
    final stdoutSub = proc.stdoutLines.listen((line) {
      final p = parseProgressLine(line);
      if (p == null) return;
      sawProgress = true;
      _emit(
        Downloading(
          bytesDone: p.doneBytes ?? p.percent,
          bytesTotal: p.totalBytes,
        ),
      );
    });

    final code = await proc.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    if (code == 0) {
      // Completed — even if cancel arrived concurrently. The honest
      // outcome then is done(cancelRequested: true), not cancelled.
      if (sawProgress) {
        _emit(const Applying());
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      _emit(Done(result: OperationResult(cancelRequested: _cancelRequested)));
    } else if (_cancelRequested) {
      // We killed it: the system is unchanged.
      await _abort(proc);
      return;
    } else {
      _emit(
        Failed(
          error: _mapError(
            FlatpakCommandException(
              ['flatpak'],
              code,
              stderrBuf.toString().trim(),
            ),
          ),
        ),
      );
    }
    await _close();
  }

  Future<void> _abort(FlatpakProcess proc) async {
    _emit(const Cancelling());
    await proc.terminate();
    _emit(const Cancelled());
    await _close();
  }

  @override
  Future<void> cancel() async {
    if (_current.isTerminal || _closed) return;
    _cancelRequested = true;
    // The _run loop notices and drives Cancelling → Cancelled.
    // If _run hasn't started the process yet, this is a no-op safeguard.
    await _process?.terminate();
  }
}
