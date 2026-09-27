/// [BackendDeb]: the deb backend, over PackageKit (D-Bus).
///
/// Mutating calls run on a dedicated PackageKit transaction whose
/// progress events [DebOperationHandle] maps onto the operation states.
/// Permissions surface the one honest pre-install signal debs offer
/// (ADR-009): debs are **unsandboxed** — full system access. That is
/// the truth, not a weakness to hide.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'handle.dart';
import 'transport.dart';

class BackendDeb extends StoreBackend {
  BackendDeb({required this.transport});

  final PackageKitTransport transport;

  @override
  String get id => 'deb';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {
    BackendCapability.search,
    BackendCapability.details,
    BackendCapability.install,
    BackendCapability.remove,
    BackendCapability.update,
    BackendCapability.permissions,
  };

  @override
  Future<bool> isAvailable() async {
    try {
      // The contract budgets 200ms: a cold daemon reads as unavailable
      // on first probe and available once warm. Never throws.
      await transport.checkAvailable().timeout(
        const Duration(milliseconds: 200),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<AppInfo> search(String query) {
    final controller = StreamController<AppInfo>();
    var cancelled = false;
    // A PackageKit search is one transaction: cancelling the
    // subscription abandons the result, which is the honest bound of
    // "stop work".
    controller.onCancel = () => cancelled = true;
    () async {
      try {
        final packages = await transport.search(query);
        for (final p in packages) {
          if (cancelled || controller.isClosed) break;
          controller.add(_toAppInfo(p));
        }
      } catch (e) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(
            e is PackageKitTransportException
                ? _mapError(e)
                : UnknownStoreException(
                    debugDetail: 'deb search failed: $e',
                    backendId: id,
                  ),
          );
        }
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }();
    return controller.stream;
  }

  AppInfo _toAppInfo(DebPackageData p) => AppInfo(
    identity: AppIdentity(backendId: id, nativeId: p.name),
    name: p.name,
    summary: p.summary,
    iconUrl: '',
    source: AppSource.deb,
    version: p.version.isEmpty ? null : p.version,
    installedVersion: p.installedVersion,
    // Identity signal from the PackageKit Details `url` entry
    // (phase3-slice2.md §1). Empty = the wire had nothing.
    identitySignal: p.url.isEmpty ? null : IdentitySignal(homepageUrl: p.url),
  );

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    late final DebPackageData p;
    try {
      p = await transport.getDetails(id.nativeId);
    } on PackageKitNotFoundException catch (e) {
      throw AppNotFoundException(debugDetail: e.message, backendId: this.id);
    } on PackageKitTransportException catch (e) {
      throw _mapError(e);
    }
    return AppDetails(
      app: _toAppInfo(p),
      description: p.description,
      permissions: _debPermissions,
      homepage: p.url.isEmpty ? null : p.url,
    );
  }

  /// Debs run unsandboxed. Say it up front.
  static const List<Permission> _debPermissions = [
    Permission(
      id: 'confinement-none',
      label: 'Unsandboxed — full system access',
    ),
  ];

  Future<bool> _isInstalled(String name) async {
    try {
      return (await transport.installedNames()).contains(name);
    } on PackageKitTransportException {
      return false;
    }
  }

  Future<DebTransaction> _begin(Future<DebTransaction> Function() start) async {
    try {
      return await start();
    } on PackageKitTransportException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<OperationHandle> install(AppIdentity app) async {
    if (await _isInstalled(app.nativeId)) {
      return DebOperationHandle.noop(app: app, kind: OperationKind.install);
    }
    final tx = await _begin(() => transport.install(app.nativeId));
    return DebOperationHandle(
      app: app,
      kind: OperationKind.install,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> remove(AppIdentity app) async {
    final tx = await _begin(() => transport.remove(app.nativeId));
    return DebOperationHandle(
      app: app,
      kind: OperationKind.remove,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> update(AppIdentity app) async {
    final tx = await _begin(() => transport.update(app.nativeId));
    return DebOperationHandle(
      app: app,
      kind: OperationKind.update,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    late final List<DebPackageData> packages;
    try {
      packages = await transport.updatesAvailable();
    } on PackageKitTransportException catch (e) {
      throw _mapError(e);
    }
    return [
      for (final p in packages)
        UpdateInfo(
          identity: AppIdentity(backendId: id, nativeId: p.name),
          name: p.name,
          fromVersion: p.installedVersion,
          toVersion: p.version.isEmpty ? null : p.version,
        ),
    ];
  }

  @override
  Future<List<AppInfo>> listInstalled() async {
    // Bulk first: one GetPackages(installed) transaction plus one
    // GetDetails batch (2 total). If the batch fails the backend
    // degrades to the N+1 legacy enumeration below — the host contract
    // is partial results, never throw.
    try {
      final packages = await transport.installedPackages();
      return [for (final p in packages) _installedAppInfo(p)];
    } on PackageKitTransportException {
      return _listInstalledLegacy();
    }
  }

  /// The pre-bulk enumeration: 1 installedNames transaction + 2 per
  /// package (SearchNames + GetDetails). Kept as the fallback for a
  /// failed bulk batch; skip-on-not-found and error mapping are
  /// unchanged from the original listInstalled().
  Future<List<AppInfo>> _listInstalledLegacy() async {
    late final List<String> names;
    try {
      names = await transport.installedNames();
    } on PackageKitTransportException catch (e) {
      throw _mapError(e);
    }
    final apps = <AppInfo>[];
    for (final name in names) {
      late final DebPackageData p;
      try {
        p = await transport.getDetails(name);
      } on PackageKitNotFoundException {
        // Removed between installedNames() and getDetails(): skip the
        // entry rather than failing the whole enumeration.
        continue;
      } on PackageKitTransportException catch (e) {
        throw _mapError(e);
      }
      apps.add(_installedAppInfo(p));
    }
    return apps;
  }

  /// Maps a package known to be installed. The PackageKit getDetails
  /// path resolves the installed package id (preferInstalled) but does
  /// not populate installedVersion, so a null falls back to the
  /// package's own version — which IS the installed one here.
  /// [AppInfo.isInstalled] must be true for every entry this returns.
  AppInfo _installedAppInfo(DebPackageData p) {
    final info = _toAppInfo(p);
    if (info.installedVersion != null) return info;
    return AppInfo(
      identity: info.identity,
      name: info.name,
      summary: info.summary,
      iconUrl: info.iconUrl,
      source: info.source,
      version: info.version,
      installedVersion: info.version ?? 'unknown',
      identitySignal: info.identitySignal,
    );
  }

  @override
  Future<List<OperationHandle>> recoverInFlight() async {
    // PackageKit owns its transactions daemon-side, but a raw
    // transaction path cannot be reliably mapped back to (package,
    // operation): the transaction object exposes no target package.
    // Returning [] is honest; crash recovery for debs is a v2 with a
    // deliberate design, not a guess. The exam tolerates empty.
    return const [];
  }

  StoreException _mapError(PackageKitTransportException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('unreachable') ||
        msg.contains('dbus') ||
        msg.contains('service unknown')) {
      return BackendUnavailableException(
        debugDetail: 'packagekit unreachable: ${e.message}',
        backendId: id,
      );
    }
    if (msg.contains('packagenotfound') ||
        msg.contains('package not found') ||
        msg.contains('packagenotinstalled') ||
        msg.contains('not installed') ||
        msg.contains('no such package')) {
      return AppNotFoundException(debugDetail: e.message, backendId: id);
    }
    if (msg.contains('nospaceondevice') ||
        msg.contains('no space') ||
        msg.contains('disk full')) {
      return const DiskSpaceException(
        debugDetail: 'packagekit reported no space left',
        neededBytes: -1,
        availableBytes: 0,
        backendId: 'deb',
      );
    }
    if (msg.contains('nonetwork') ||
        msg.contains('network') ||
        msg.contains('timeout')) {
      return NetworkException(debugDetail: e.message, backendId: id);
    }
    if (msg.contains('permission') ||
        msg.contains('access denied') ||
        msg.contains('unauthorized') ||
        msg.contains('not authorized')) {
      return PermissionException(
        debugDetail: e.message,
        neededAccess: 'packagekit system action access (polkit)',
        backendId: id,
      );
    }
    return UnknownStoreException(debugDetail: e.message, backendId: id);
  }
}
