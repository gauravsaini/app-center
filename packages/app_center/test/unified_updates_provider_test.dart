import 'package:app_center/manage/unified_updates_provider.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Provider tests for the updates strangler-fig slice:
/// `unifiedUpdatesProvider` -> `StoreHost.checkUpdates()` -> backends,
/// with the `pages.updates.unified` flag on.
void main() {
  tearDown(resetAllServices);

  group('unifiedUpdatesProvider', () {
    test(
      'canned UpdateInfos flow through with count and fields intact',
      () async {
        final flags = MapFeatureFlags({
          'pages.updates.unified': true,
          'backend.fake.enabled': true,
        });
        final host = StoreHost(flags: flags)
          ..registerBackend(
            _StubUpdatesBackend([
              _update(
                'fake.app1',
                'Fake App One',
                from: '1.0',
                to: '2.0',
                size: 1024,
              ),
              _update('fake.app2', 'Fake App Two', from: '3.1', to: '3.2'),
              _update('fake.app3', 'Fake App Three'),
            ]),
          );
        final container = createContainer(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
        );

        final updates = await container.read(unifiedUpdatesProvider.future);

        expect(updates, hasLength(3));
        expect(updates[0].name, 'Fake App One');
        expect(updates[0].fromVersion, '1.0');
        expect(updates[0].toVersion, '2.0');
        expect(updates[0].sizeBytes, 1024);
        expect(
          updates[0].identity,
          AppIdentity(backendId: 'fake', nativeId: 'fake.app1'),
        );
        expect(updates[1].name, 'Fake App Two');
        expect(updates[1].fromVersion, '3.1');
        expect(updates[1].toVersion, '3.2');
        // Nullable fields a backend may omit.
        expect(updates[2].name, 'Fake App Three');
        expect(updates[2].fromVersion, isNull);
        expect(updates[2].toVersion, isNull);
        expect(updates[2].sizeBytes, isNull);
        expect(
          updates[2].identity,
          AppIdentity(backendId: 'fake', nativeId: 'fake.app3'),
        );
      },
    );

    test('no enabled backends resolves to an empty list', () async {
      final flags = MapFeatureFlags({'pages.updates.unified': true});
      // No backends registered: checkUpdates() is [].
      final host = StoreHost(flags: flags);
      final container = createContainer(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
        ],
      );

      expect(await container.read(unifiedUpdatesProvider.future), isEmpty);
    });

    test(
      'a failing backend degrades to partial results, provider still resolves',
      () async {
        final flags = MapFeatureFlags({
          'pages.updates.unified': true,
          'backend.fake.enabled': true,
          'backend.broken.enabled': true,
        });
        final host = StoreHost(flags: flags)
          ..registerBackend(
            _StubUpdatesBackend([_update('fake.app1', 'Fake App One')]),
          )
          ..registerBackend(_ThrowingUpdatesBackend());
        final container = createContainer(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
        );

        final updates = await container.read(unifiedUpdatesProvider.future);

        expect(updates, hasLength(1));
        expect(updates.single.name, 'Fake App One');
      },
    );
  });
}

UpdateInfo _update(
  String nativeId,
  String name, {
  String? from,
  String? to,
  int? size,
}) => UpdateInfo(
  identity: AppIdentity(backendId: 'fake', nativeId: nativeId),
  name: name,
  fromVersion: from,
  toVersion: to,
  sizeBytes: size,
);

/// Minimal backend stub whose only real behavior is [checkUpdates].
/// Everything else is a no-op — enough for the host fan-out.
class _StubUpdatesBackend extends StoreBackend {
  _StubUpdatesBackend(this._updates);

  final List<UpdateInfo> _updates;

  @override
  String get id => 'fake';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => const {BackendCapability.update};

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => const Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> install(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> remove(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> update(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<List<UpdateInfo>> checkUpdates() async => _updates;

  @override
  Future<List<AppInfo>> listInstalled() async => const [];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}

/// Backend whose [checkUpdates] throws: pins the host's partial-results
/// degradation through the provider.
class _ThrowingUpdatesBackend extends _StubUpdatesBackend {
  _ThrowingUpdatesBackend() : super(const []);

  @override
  String get id => 'broken';

  @override
  Future<List<UpdateInfo>> checkUpdates() => Future.error(
    BackendUnavailableException(
      debugDetail: 'stub broken backend',
      backendId: 'broken',
    ),
  );
}
