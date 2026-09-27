/// Scriptable [OperationHandle] for widget tests.
///
/// Emits scripted states on demand over a broadcast stream (no replay —
/// mirrors the real contract); `cancel()` records the call count and emits
/// [Cancelling].
library;

import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:store_host/store_host.dart';

class FakeInFlightHandle extends Fake implements OperationHandle {
  FakeInFlightHandle({
    required this.app,
    this.kind = OperationKind.install,
    OperationState initial = const Queued(position: 0),
  }) : _current = initial;

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  final _controller = StreamController<OperationState>.broadcast();
  OperationState _current;

  int cancelCallCount = 0;

  /// Script a state transition. Mirrors how the real handle pushes
  /// states onto its stream; synchronous for broadcast subscribers.
  void emit(OperationState state) {
    _current = state;
    _controller.add(state);
  }

  @override
  OperationState get current => _current;

  @override
  Stream<OperationState> get state => _controller.stream;

  @override
  Future<void> cancel() async {
    cancelCallCount++;
    emit(const Cancelling());
  }

  Future<void> dispose() => _controller.close();
}
