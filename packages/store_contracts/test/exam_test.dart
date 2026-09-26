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
        installTarget:
            const AppIdentity(backendId: 'fake', nativeId: 'org.fake.App'),
        unknownTarget:
            const AppIdentity(backendId: 'fake', nativeId: 'no.such.App'),
        installedTarget:
            const AppIdentity(backendId: 'fake', nativeId: 'org.fake.Installed'),
      );
    });

    test('catches a backend that emits an illegal transition', () async {
      // Sanity: the exam must actually bite. Drive a handle manually
      // through Queued → Done (non-noop) and assert the DAG check fires.
      await expectLater(
        runContractExam(
          'fake-broken',
          _BrokenBackend.new,
          installTarget:
              const AppIdentity(backendId: 'fake', nativeId: 'org.fake.App'),
          unknownTarget:
              const AppIdentity(backendId: 'fake', nativeId: 'no.such.App'),
        ),
        throwsA(isA<ExamFailure>()),
      );
    });
  });
}

/// A backend whose install jumps Queued → Done without noop — illegal.
class _BrokenBackend extends FakeStoreBackend {
  @override
  Future<OperationHandle> install(AppIdentity id) async =>
      _BrokenHandle(app: id);
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
      const Done(result: OperationResult(installedVersion: '1.0')));

  @override
  Future<void> cancel() async {}
}
