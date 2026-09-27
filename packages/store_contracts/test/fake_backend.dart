/// In-memory fake backend proving the exam is sound (dogfooding).
/// Real backends run the exam with a stubbed transport instead.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

AppInfo _fakeApp(String nativeId, String name) => AppInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
  summary: 'A fake app for the contract exam.',
  iconUrl: '',
  source: AppSource.unknown,
  version: '1.0',
);

class FakeStoreBackend extends StoreBackend {
  /// When true, install() drives to Failed(NetworkException).
  bool failInstalls = false;

  @override
  String get id => 'fake';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {
    BackendCapability.search,
    BackendCapability.details,
    BackendCapability.install,
    BackendCapability.remove,
    BackendCapability.update,
  };

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) async* {
    yield _fakeApp('org.fake.App1', 'Fake App 1 $query');
    yield _fakeApp('org.fake.App2', 'Fake App 2 $query');
  }

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    if (id.nativeId == 'no.such.App') {
      throw AppNotFoundException(
        debugDetail: 'fake backend has no ${id.nativeId}',
        backendId: 'fake',
      );
    }
    return AppDetails(
      app: _fakeApp(id.nativeId, id.nativeId),
      description: 'Fake details.',
    );
  }

  @override
  Future<OperationHandle> install(AppIdentity id) async {
    // Idempotent no-op path for the exam's installed target.
    if (id.nativeId == 'org.fake.Installed') {
      return _FakeHandle(
        app: id,
        kind: OperationKind.install,
        script: const [Done(result: OperationResult(noop: true))],
      );
    }
    if (failInstalls) {
      return _FakeHandle(
        app: id,
        kind: OperationKind.install,
        script: const [
          Preparing(),
          Downloading(bytesDone: 10, bytesTotal: 100),
          Failed(
            error: NetworkException(
              debugDetail: 'fake network failure',
              backendId: 'fake',
            ),
          ),
        ],
      );
    }
    return _FakeHandle(app: id, kind: OperationKind.install);
  }

  @override
  Future<OperationHandle> remove(AppIdentity id) => install(id); // shape is identical for the exam

  @override
  Future<OperationHandle> update(AppIdentity id) => install(id);

  @override
  Future<List<UpdateInfo>> checkUpdates() async => [];

  @override
  Future<List<AppInfo>> listInstalled() async => [
    _fakeApp('org.fake.InstalledApp1', 'Fake Installed App 1'),
    _fakeApp('org.fake.InstalledApp2', 'Fake Installed App 2'),
  ];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => [];
}

class _FakeHandle implements OperationHandle {
  _FakeHandle({
    required this.app,
    required this.kind,
    List<OperationState>? script,
  }) : _script =
           script ??
           const [
             Preparing(),
             Downloading(bytesDone: 0, bytesTotal: 100),
             Downloading(bytesDone: 50, bytesTotal: 100),
             Downloading(bytesDone: 100, bytesTotal: 100),
             Applying(fraction: 0.5),
             Applying(fraction: 1.0),
             Done(result: OperationResult(installedVersion: '1.0')),
           ],
       _current = const Queued(position: 0) {
    unawaited(_run());
  }

  final List<OperationState> _script;
  final _controller = StreamController<OperationState>.broadcast();
  OperationState _current;
  bool _cancelRequested = false;

  @override
  String get id => 'fake-${app.nativeId}-${kind.name}';

  @override
  final AppIdentity app;

  @override
  final OperationKind kind;

  @override
  Stream<OperationState> get state => _controller.stream;

  @override
  OperationState get current => _current;

  void _emit(OperationState s) {
    _current = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  Future<void> _run() async {
    for (final s in _script) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (_cancelRequested) {
        _emit(const Cancelling());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        _emit(const Cancelled());
        await _controller.close();
        return;
      }
      _emit(s);
      if (s.isTerminal) {
        await _controller.close();
        return;
      }
    }
    // Script exhausted without terminal — a backend bug; fail loudly.
    if (!_current.isTerminal) {
      _emit(
        const Failed(
          error: UnknownStoreException(
            debugDetail: 'fake script exhausted without terminal state',
            backendId: 'fake',
          ),
        ),
      );
    }
    await _controller.close();
  }

  @override
  Future<void> cancel() async {
    if (_current.isTerminal) return;
    _cancelRequested = true;
  }
}
