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

  group('unifiedUpdatesResultProvider', () {
    test('exposes partialBackendIds when a backend is excluded', () async {
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

      final result = await container.read(
        unifiedUpdatesResultProvider.future,
      );

      expect(result.updates, hasLength(1));
      expect(result.partialBackendIds, ['broken']);
      expect(result.isPartial, isTrue);
    });

    test('full check is not partial', () async {
      final flags = MapFeatureFlags({
        'pages.updates.unified': true,
        'backend.fake.enabled': true,
      });
      final host = StoreHost(flags: flags)
        ..registerBackend(
          _StubUpdatesBackend([_update('fake.app1', 'Fake App One')]),
        );
      final container = createContainer(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
        ],
      );

      final result = await container.read(
        unifiedUpdatesResultProvider.future,
      );

      expect(result.partialBackendIds, isEmpty);
      expect(result.isPartial, isFalse);
    });

    test(
      'unifiedUpdatesProvider projects .updates; one fetch is shared',
      () async {
        final flags = MapFeatureFlags({
          'pages.updates.unified': true,
          'backend.fake.enabled': true,
        });
        final host = _CountingHost(flags: flags)
          ..registerBackend(
            _StubUpdatesBackend([_update('fake.app1', 'Fake App One')]),
          );
        final container = createContainer(
          overrides: [
            storeFlagsProvider.overrideWithValue(flags),
            storeHostProvider.overrideWithValue(host),
          ],
        );

        // Watching both providers must not double-fetch: the
        // projection joins the result provider's in-flight fetch.
        container.listen(unifiedUpdatesResultProvider, (_, _) {});
        container.listen(unifiedUpdatesProvider, (_, _) {});
        final result = await container.read(
          unifiedUpdatesResultProvider.future,
        );
        final projected = await container.read(unifiedUpdatesProvider.future);

        expect(host.detailedCalls, 1);
        expect(projected, result.updates);
        expect(projected.single.name, 'Fake App One');
      },
    );
  });
}

/// [StoreHost] counting `checkUpdatesDetailed()` calls — proves the
/// result provider and its projection share one fetch.
class _CountingHost extends StoreHost {
  _CountingHost({required super.flags});

  int detailedCalls = 0;

  @override
  Future<CheckUpdatesResult> checkUpdatesDetailed() async {
    detailedCalls++;
    return super.checkUpdatesDetailed();
  }
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
