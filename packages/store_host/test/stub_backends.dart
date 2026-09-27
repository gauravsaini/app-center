/// Test-only backends for the host tests. Never touch the live system.
library;

import 'package:backend_flatpak/backend_flatpak.dart'
    show FlatpakCommandException, FlatpakProcess, FlatpakTransport;
import 'package:store_host/store_host.dart';

export 'package:backend_flatpak/testing.dart';

/// Minimal second backend (stands in for a future snap backend).
class StubSnapBackend extends StoreBackend {
  @override
  String get id => 'snap';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {
    BackendCapability.search,
    BackendCapability.install,
  };

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AppInfo> search(String query) => Stream.value(
    AppInfo(
      identity: const AppIdentity(backendId: 'snap', nativeId: 'snap.test.App'),
      name: 'Snap Test App',
      summary: '',
      iconUrl: '',
      source: AppSource.snap,
    ),
  );

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> install(AppIdentity app) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> remove(AppIdentity app) =>
      throw UnimplementedError('stub');

  @override
  Future<OperationHandle> update(AppIdentity app) =>
      throw UnimplementedError('stub');

  @override
  Future<List<UpdateInfo>> checkUpdates() async => const [];

  @override
  Future<List<OperationHandle>> recoverInFlight() async => const [];
}

/// A backend whose search always throws — proves partial degradation.
class ThrowingSearchBackend extends StubSnapBackend {
  @override
  String get id => 'thrower';

  @override
  Stream<AppInfo> search(String query) => Stream.error(Exception('boom'));
}

/// A backend returning canned installed apps — never overrides anything
/// except the identity and the installed list.
class StubInstalledBackend extends StubSnapBackend {
  StubInstalledBackend({required this.backendId, required List<AppInfo> apps})
    : _apps = apps;

  final String backendId;
  final List<AppInfo> _apps;

  @override
  String get id => backendId;

  @override
  Future<List<AppInfo>> listInstalled() async => _apps;
}

AppInfo stubInstalledApp(String backendId, String nativeId) => AppInfo(
  identity: AppIdentity(backendId: backendId, nativeId: nativeId),
  name: 'Installed $nativeId',
  summary: '',
  iconUrl: '',
  source: AppSource.unknown,
  installedVersion: '1.0',
);

/// A backend whose listInstalled always throws a typed error — proves
/// installed() degrades to partial results instead of failing.
class ThrowingInstalledBackend extends StubSnapBackend {
  @override
  String get id => 'thrower';

  @override
  Future<List<AppInfo>> listInstalled() => throw BackendUnavailableException(
    debugDetail: 'thrower cannot enumerate installed apps',
    backendId: 'thrower',
  );
}

/// Flatpak transport whose every command fails — proves the host
/// excludes unavailable backends even when the flag is on.
class FailingFlatpakTransport extends FlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) =>
      throw FlatpakCommandException(args, 127, 'no flatpak here');

  @override
  FlatpakProcess spawn(List<String> args) =>
      throw FlatpakCommandException(args, 127, 'no flatpak here');
}
