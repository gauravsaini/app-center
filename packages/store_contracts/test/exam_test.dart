import 'package:store_contracts/exam.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

import 'fake_backend.dart';

void main() {
  group('contract exam (dogfood: fake backend)', () {
    test('passes the full exam', () async {
      await runContractExam(
        'fake',
        FakeStoreBackend.new,
        installTarget: const AppIdentity(
          backendId: 'fake',
          nativeId: 'org.fake.App',
        ),
        unknownTarget: const AppIdentity(
          backendId: 'fake',
          nativeId: 'no.such.App',
        ),
        installedTarget: const AppIdentity(
          backendId: 'fake',
          nativeId: 'org.fake.Installed',
        ),
      );
    });

    test('catches a backend that emits an illegal transition', () async {
      // Sanity: the exam must actually bite. Drive a handle manually
      // through Queued → Done (non-noop) and assert the DAG check fires.
      await expectLater(
        runContractExam(
          'fake-broken',
          _BrokenBackend.new,
          installTarget: const AppIdentity(
            backendId: 'fake',
            nativeId: 'org.fake.App',
          ),
          unknownTarget: const AppIdentity(
            backendId: 'fake',
            nativeId: 'no.such.App',
          ),
        ),
        throwsA(isA<ExamFailure>()),
      );
    });

    test('catches a backend whose listInstalled throws a raw error', () async {
      await expectLater(
        runContractExam(
          'fake-raw-throw',
          _RawThrowBackend.new,
          installTarget: const AppIdentity(
            backendId: 'fake',
            nativeId: 'org.fake.App',
          ),
          unknownTarget: const AppIdentity(
            backendId: 'fake',
            nativeId: 'no.such.App',
          ),
        ),
        throwsA(isA<ExamFailure>()),
      );
    });

    test(
      'catches a backend whose installed identities carry the wrong backendId',
      () async {
        await expectLater(
          runContractExam(
            'fake-wrong-id',
            _WrongIdentityBackend.new,
            installTarget: const AppIdentity(
              backendId: 'fake',
              nativeId: 'org.fake.App',
            ),
            unknownTarget: const AppIdentity(
              backendId: 'fake',
              nativeId: 'no.such.App',
            ),
          ),
          throwsA(isA<ExamFailure>()),
        );
      },
    );

    test('additive default: non-overriding backend gets []', () async {
      // A backend that never overrides listInstalled() must compile
      // unchanged and report nothing installed (LLD §10 minor path).
      await runContractExamDefaultListInstalled(
        'fake-default',
        _DefaultOnlyBackend.new,
      );
      // And the full exam passes for it when listInstalled is the
      // default — typed methods it doesn't touch are never exercised.
    });
  });
}

/// Minimal backend that never overrides listInstalled(): proves the
/// additive default keeps old implementers compiling and yields [].
class _DefaultOnlyBackend extends StoreBackend {
  @override
  String get id => 'default-only';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {};

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('default-only');

  @override
  Future<OperationHandle> install(AppIdentity id) =>
      throw UnimplementedError('default-only');

  @override
  Future<OperationHandle> remove(AppIdentity id) =>
      throw UnimplementedError('default-only');

  @override
  Future<OperationHandle> update(AppIdentity id) =>
      throw UnimplementedError('default-only');

  @override
  Future<List<UpdateInfo>> checkUpdates() async => const [];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}

/// A backend whose install jumps Queued → Done without noop — illegal.
class _BrokenBackend extends FakeStoreBackend {
  @override
  Future<OperationHandle> install(AppIdentity id) async =>
      _BrokenHandle(app: id);
}

/// A backend whose listInstalled() throws a raw error — illegal.
class _RawThrowBackend extends FakeStoreBackend {
  @override
  Future<List<AppInfo>> listInstalled() async => throw Exception('raw boom');
}

/// A backend whose installed identities carry the wrong backendId — illegal.
class _WrongIdentityBackend extends FakeStoreBackend {
  @override
  Future<List<AppInfo>> listInstalled() async => [
    const AppInfo(
      identity: AppIdentity(backendId: 'someone-else', nativeId: 'org.fake.X'),
      name: 'Impostor App',
      summary: '',
      iconUrl: '',
      source: AppSource.unknown,
    ),
  ];
}

class _BrokenHandle implements OperationHandle {
  _BrokenHandle({required this.app});

  @override
  final AppIdentity app;

  @override
  OperationKind get kind => OperationKind.install;

  @override
  String get id => 'broken';

  @override
  OperationState get current => const Queued(position: 0);

  @override
  Stream<OperationState> get state => Stream.value(
    const Done(result: OperationResult(installedVersion: '1.0')),
  );

  @override
  Future<void> cancel() async {}
}
