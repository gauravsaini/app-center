/// Backend heartbeat helper for the stall watchdog
/// (`docs/architecture/stall-watchdog.md`, `operation-state-machine.md` §4).
///
/// During `downloading`/`applying`, a backend MUST emit a state event at
/// least every [interval] even if nothing changed. The heartbeat proves
/// the backend's event loop is alive; the engine never synthesizes
/// liveness. Zero dependencies; the clock is injectable for tests.
library;

import 'operation.dart';

class PhaseHeartbeat {
  PhaseHeartbeat({
    this.interval = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Contract §4: at least one event per 60s during
  /// downloading/applying.
  final Duration interval;

  final DateTime Function() _clock;
  DateTime? _lastEmit;

  /// Record that a state event was emitted. Backends call this on every
  /// emission, including the phase-entering one.
  void markEmitted() {
    _lastEmit = _clock();
  }

  /// True when [state] is downloading/applying AND no emission has been
  /// recorded for >= [interval]. False for every other phase — only
  /// downloading/applying heartbeat, never queued/authenticating/
  /// preparing/verifying/cancelling/terminal.
  bool shouldBeat(OperationState state) {
    if (state is! Downloading && state is! Applying) return false;
    final last = _lastEmit;
    if (last == null) return false;
    return _clock().difference(last) >= interval;
  }
}
