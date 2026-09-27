/// Stall watchdog tests (docs/architecture/stall-watchdog.md §9, §10).
///
/// A fake [TimerFactory] with manual [FakeTimerFactory.advance] drives
/// the engine's clock — no real-time sleeps, no wall-clock reads.
library;

import 'dart:async';

import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

import 'stub_backends.dart';

/// Lets async broadcast deliveries land. Zero-duration: not a sleep,
/// just event-loop turns.
Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Scriptable [Timer] with manual time: [FakeTimerFactory.advance] fires
/// every armed timer whose deadline falls inside the advanced window,
/// in deadline order. Firing callbacks may arm/cancel other timers —
/// the timer deactivates itself before invoking the callback, so
/// re-entrancy is safe.
class FakeTimerFactory {
  FakeTimerFactory();

  Duration _now = Duration.zero;
  final _timers = <_FakeTimer>[];

  Timer call(Duration duration, void Function() callback) {
    final timer = _FakeTimer(_now + duration, callback, _timers.remove);
    _timers.add(timer);
    return timer;
  }

  /// Currently armed (not fired, not cancelled) timers.
  int get pendingCount => _timers.where((t) => t.isActive).length;

  void advance(Duration by) {
    final target = _now + by;
    for (;;) {
      _FakeTimer? next;
      for (final t in _timers) {
        if (!t.isActive || t.due > target) continue;
        if (next == null || t.due < next.due) next = t;
      }
      if (next == null) break;
      _now = next.due;
      next.fire();
    }
    _now = target;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this._callback, this._onFired);

  Duration due;
  final void Function() _callback;
  final void Function(_FakeTimer) _onFired;
  var _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _onFired(this);
    _callback();
  }
}

/// Scriptable [OperationHandle]: the test drives state events by hand.
/// The stream is sync so the wrapper processes each emission before
/// `emit` returns — deterministic arming without event-loop turns.
/// (The wrapper's own fan-out stays async, like real backends.)
class ScriptableHandle implements OperationHandle {
  ScriptableHandle(this._current);

  final _states = StreamController<OperationState>.broadcast(sync: true);
  OperationState _current;
  var cancelCalls = 0;

  @override
  String get id => 'script-op';

  @override
  AppIdentity get app =>
      const AppIdentity(backendId: 'script', nativeId: 'org.test.Script');

  @override
  OperationKind get kind => OperationKind.install;

  @override
  Stream<OperationState> get state => _states.stream;

  @override
  OperationState get current => _current;

  void emit(OperationState state) {
    _current = state;
    _states.add(state);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

/// Backend handing out a pre-built scriptable handle for installs.
class ScriptableBackend extends StubSnapBackend {
  ScriptableBackend(this.next);

  final ScriptableHandle next;

  @override
  String get id => 'script';

  @override
  Future<OperationHandle> install(AppIdentity app) async => next;
}

const _scriptApp = AppIdentity(
  backendId: 'script',
  nativeId: 'org.test.Script',
);
const _stallTimeout = Duration(seconds: 100);

({StoreHost host, ScriptableHandle inner, FakeTimerFactory timers}) makeWatched(
  ScriptableHandle inner, {
  Map<String, Object>? flags,
}) {
  final timers = FakeTimerFactory();
  final host = StoreHost(
    flags: MapFeatureFlags({
      'backend.script.enabled': true,
      'engine.stall_timeout_ms': _stallTimeout.inMilliseconds,
      ...?flags,
    }),
    timerFactory: timers.call,
  );
  host.registerBackend(ScriptableBackend(inner));
  return (host: host, inner: inner, timers: timers);
}

StallAware asStallAware(OperationHandle handle) {
  expect(handle, isA<StallAware>());
  return handle as StallAware;
}

void main() {
  group('stall watchdog', () {
    test('flag default is 10 minutes, not 30 seconds', () {
      // docs/architecture/stall-watchdog.md §5: a 30s default would
      // false-positive against the 60s backend heartbeat. The flag was
      // never consumed before this slice, so the change is safe.
      expect(MapFeatureFlags().getInt('engine.stall_timeout_ms'), 600000);
    });

    test('stall fires after the timeout with no events in applying', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);
      final aware = asStallAware(handle);
      final stalledEvents = <bool>[];
      aware.stalledChanges.listen(stalledEvents.add);

      w.timers.advance(_stallTimeout);
      await _pump();

      expect(aware.isStalled, isTrue);
      expect(stalledEvents, [true]);
      expect(w.inner.cancelCalls, 1);
    });

    test('an event just before the deadline re-arms the timer', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);

      w.timers.advance(_stallTimeout - const Duration(seconds: 1));
      w.inner.emit(const Applying()); // re-arms: new deadline +100s
      w.timers.advance(_stallTimeout - const Duration(seconds: 1));

      // 198s elapsed, but the timer re-armed at 99s — no stall.
      expect(asStallAware(handle).isStalled, isFalse);
      expect(w.inner.cancelCalls, 0);
    });

    test('a terminal event disarms the watchdog', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);
      final events = <OperationState>[];
      handle.state.listen(events.add);

      w.inner.emit(const Done(result: OperationResult()));
      w.timers.advance(_stallTimeout * 2);
      await _pump();

      expect(asStallAware(handle).isStalled, isFalse);
      expect(w.inner.cancelCalls, 0);
      expect(w.timers.pendingCount, 0);
      expect(events.last, isA<Done>());
    });

    test('queued and authenticating never arm the timer', () async {
      final w = makeWatched(ScriptableHandle(const Queued(position: 0)));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);

      w.timers.advance(_stallTimeout * 2);

      expect(w.timers.pendingCount, 0);
      expect(asStallAware(handle).isStalled, isFalse);
      expect(w.inner.cancelCalls, 0);
    });

    test('an unwatched phase disarms an armed timer', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);
      expect(w.timers.pendingCount, 1);

      // queued is engine-owned waiting, not backend work — the timer
      // must not fire while the op legitimately waits.
      w.inner.emit(const Queued(position: 0));
      expect(w.timers.pendingCount, 0);

      w.timers.advance(_stallTimeout * 2);
      expect(asStallAware(handle).isStalled, isFalse);
      expect(w.inner.cancelCalls, 0);
    });

    test('watchdog cancel acked by the backend forwards the terminal, '
        'no synthetic failure', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);
      final events = <OperationState>[];
      handle.state.listen(events.add);
      final aware = asStallAware(handle);

      w.timers.advance(_stallTimeout);
      expect(aware.isStalled, isTrue);
      expect(w.inner.cancelCalls, 1);

      // The backend acknowledges the watchdog's cancel and winds down.
      w.inner.emit(const Cancelling());
      w.inner.emit(const Cancelled());
      await _pump();
      // Well past the 30s grace: nothing synthetic may appear.
      w.timers.advance(const Duration(seconds: 120));
      await _pump();

      expect(events.map((e) => e.runtimeType).toList(), [
        Cancelling,
        Cancelled,
      ]);
      // Advisory flag stays: the op did stall, even though it then
      // shut down cleanly.
      expect(aware.isStalled, isTrue);
    });

    test('grace expiry synthesizes Failed(TimeoutException); '
        'later inner events are ignored', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);
      final events = <OperationState>[];
      handle.state.listen(events.add);

      w.timers.advance(_stallTimeout); // stall fires, grace starts
      w.timers.advance(const Duration(seconds: 30)); // grace expires
      await _pump();

      expect(events.length, 1);
      final failed = events.single as Failed;
      expect(failed.error, isA<TimeoutException>());
      final error = failed.error as TimeoutException;
      expect(error.stalledPhase, 'Applying');
      expect(error.debugDetail, contains('Applying'));

      // The backend finally terminating changes nothing: the wrapper
      // detached at the synthetic terminal.
      w.inner.emit(const Cancelled());
      await _pump();
      expect(events.length, 1);
    });

    test('user cancel() delegates to the inner handle', () async {
      final w = makeWatched(ScriptableHandle(const Applying()));
      final handle = await w.host.enqueue(OperationKind.install, _scriptApp);

      await handle.cancel();

      expect(w.inner.cancelCalls, 1);
      // A user cancel doesn't touch watchdog state.
      expect(asStallAware(handle).isStalled, isFalse);
    });
  });
}
