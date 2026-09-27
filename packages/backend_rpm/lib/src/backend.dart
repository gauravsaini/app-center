/// [BackendRpm]: the RPM backend, over PackageKit (D-Bus) against the
/// dnf5 backend.
///
/// Mutating calls run on a dedicated PackageKit transaction whose
/// progress events [RpmOperationHandle] maps onto the operation states.
/// Card identity is (name, arch) — multi-arch packages are separate
/// cards (research §5). Every result is labeled [AppSource.rpm], never
/// deb (HLD §5).
///
/// Permissions surface the one honest pre-install signal RPMs offer
/// (ADR-009): RPMs are **unsandboxed** — full system access. That is
/// the truth, not a weakness to hide.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'handle.dart';
import 'identity.dart';
import 'metadata.dart';
import 'transport.dart';

class BackendRpm extends StoreBackend {
  BackendRpm({required this.transport});

  final RpmTransport transport;

  @override
  String get id => 'rpm';

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
            e is RpmTransportException
                ? _mapError(e)
                : UnknownStoreException(
                    debugDetail: 'rpm search failed: $e',
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

  AppInfo _toAppInfo(RpmPackageData p) => AppInfo(
    identity: AppIdentity(backendId: id, nativeId: p.id),
    name: p.name,
    summary: p.summary,
    iconUrl: '', // no icons on the PackageKit D-Bus surface (HLD §2)
    source: AppSource.rpm, // NEVER deb (HLD §5)
    version: displayVersion(p.evr),
    installedVersion: p.installed ? (p.installedEvr ?? p.evr) : null,
    // Identity signal from the homepage already flowing end-to-end
    // (phase3-slice2.md §1). Empty = the wire had nothing.
    identitySignal: p.homepage.isEmpty
        ? null
        : IdentitySignal(homepageUrl: p.homepage),
  );

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    // A corrupt stored id is "not found", never a crash (LLD §6).
    try {
      parsePackageId(id.nativeId);
    } on FormatException catch (e) {
      throw AppNotFoundException(
        debugDetail: 'corrupt rpm package id: $e',
        backendId: this.id,
      );
    }
    late final RpmPackageData p;
    try {
      p = await transport.getDetails(id.nativeId);
    } on RpmNotFoundException catch (e) {
      throw AppNotFoundException(debugDetail: e.message, backendId: this.id);
    } on RpmTransportException catch (e) {
      throw _mapError(e);
    }
    return AppDetails(
      app: _toAppInfo(p),
      description:
          '${p.description.isEmpty ? p.summary : p.description}\n\n$unsandboxedDisclosure',
      permissions: _rpmPermissions,
      license: p.license.isEmpty ? null : p.license,
      homepage: p.homepage.isEmpty ? null : p.homepage,
    );
  }

  /// RPMs run unsandboxed. Say it up front — in the permission list
  /// and appended to the description (LLD §6).
  static const List<Permission> _rpmPermissions = [
    Permission(
      id: 'confinement-none',
      label: 'Unsandboxed — full system access',
    ),
  ];

  static const String unsandboxedDisclosure =
      'RPM packages run unsandboxed with full system access.';

  /// True when (name, arch) parsed from [nativeId] is installed.
  /// Origin/repo fields shift between query and transaction, so the
  /// comparison is by card key, never by verbatim id.
  Future<bool> _isInstalledCard(String nativeId) async {
    late final String cardKey;
    try {
      cardKey = parsePackageId(nativeId).cardKey;
    } on FormatException {
      return false;
    }
    late final List<String> ids;
    try {
      ids = await transport.installedIds();
    } on RpmTransportException {
      return false;
    }
    for (final id in ids) {
      try {
        if (parsePackageId(id).cardKey == cardKey) return true;
      } on FormatException {
        continue; // skip garbage; never fail the check
      }
    }
    return false;
  }

  Future<RpmTransaction> _begin(Future<RpmTransaction> Function() start) async {
    try {
      return await start();
    } on RpmTransportException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<OperationHandle> install(AppIdentity app) async {
    if (await _isInstalledCard(app.nativeId)) {
      return RpmOperationHandle.noop(app: app, kind: OperationKind.install);
    }
    final tx = await _begin(() => transport.install(app.nativeId));
    return RpmOperationHandle(
      app: app,
      kind: OperationKind.install,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> remove(AppIdentity app) async {
    // Contract §6 prefers the cheap noop: no transaction when the
    // (name, arch) card isn't installed.
    if (!await _isInstalledCard(app.nativeId)) {
      return RpmOperationHandle.noop(app: app, kind: OperationKind.remove);
    }
    final tx = await _begin(() => transport.remove(app.nativeId));
    return RpmOperationHandle(
      app: app,
      kind: OperationKind.remove,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> update(AppIdentity app) async {
    final tx = await _begin(() => transport.update(app.nativeId));
    return RpmOperationHandle(
      app: app,
      kind: OperationKind.update,
      transaction: tx,
      mapError: _mapError,
      // The daemon reports an empty update as plain success; the
      // handle maps that to Done(noop: true) (LLD §8).
      emptySuccessIsNoop: true,
    );
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    late final List<RpmPackageData> packages;
    try {
      packages = await transport.updatesAvailable();
    } on RpmTransportException catch (e) {
      throw _mapError(e);
    }
    return [
      for (final p in packages)
        UpdateInfo(
          identity: AppIdentity(backendId: id, nativeId: p.id),
          name: p.name,
          fromVersion: p.installedEvr,
          toVersion: displayVersion(p.evr),
        ),
    ];
  }

  @override
  Future<List<AppInfo>> listInstalled() async {
    // Bulk first: one GetPackages(installed) transaction plus one
    // GetDetails batch (2 total). If the batch fails the backend
    // degrades to the legacy per-package enumeration below — the host
    // contract is partial results, never throw.
    try {
      final packages = await transport.installedPackages();
      return [for (final p in packages) _toAppInfo(p)];
    } on RpmTransportException {
      return _listInstalledLegacy();
    }
  }

  /// The pre-bulk enumeration: installedIds + one getDetails per id.
  /// Skip-on-not-found (removed between the two calls); any other
  /// transport failure is a real error — same split as the deb backend
  /// (LLD §3.1).
  Future<List<AppInfo>> _listInstalledLegacy() async {
    late final List<String> ids;
    try {
      ids = await transport.installedIds();
    } on RpmTransportException catch (e) {
      throw _mapError(e);
    }
    final apps = <AppInfo>[];
    for (final id in ids) {
      late final RpmPackageData p;
      try {
        p = await transport.getDetails(id);
      } on RpmNotFoundException {
        // Removed between installedIds() and getDetails(): skip the
        // entry rather than failing the whole enumeration.
        continue;
      } on RpmTransportException catch (e) {
        throw _mapError(e);
      }
      apps.add(_toAppInfo(p));
    }
    return apps;
  }

  @override
  String identityLookupKey(AppIdentity identity) {
    // Arch-agnostic identity (phase3-identity-lld.md §3): the card key
    // is `name.arch`, but the identity key is the bare name.
    // Total function: a corrupt id degrades to the nativeId, never
    // throws.
    try {
      return parsePackageId(identity.nativeId).name;
    } on FormatException {
      return identity.nativeId;
    }
  }

  @override
  Future<List<OperationHandle>> recoverInFlight() async {
    // PackageKit owns its transactions daemon-side, but a raw
    // transaction path cannot be reliably mapped back to (package,
    // operation): the transaction object exposes no target package.
    // Returning [] is honest; crash recovery for rpms is a v2 with a
    // deliberate design, not a guess. The exam tolerates empty.
    return const [];
  }

  StoreException _mapError(RpmTransportException e) {
    if (e is RpmNotFoundException) {
      return AppNotFoundException(debugDetail: e.message, backendId: id);
    }
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
      return DiskSpaceException(
        debugDetail: 'packagekit reported no space left',
        neededBytes: -1,
        availableBytes: 0,
        backendId: id,
      );
    }
    if (msg.contains('nonetwork') ||
        msg.contains('network') ||
        msg.contains('timeout')) {
      return NetworkException(debugDetail: e.message, backendId: id);
    }
    if (msg.contains('notauthorized') ||
        msg.contains('not authorized') ||
        msg.contains('permission') ||
        msg.contains('access denied') ||
        msg.contains('unauthorized')) {
      return PermissionException(
        debugDetail: e.message,
        neededAccess: 'packagekit system action access (polkit)',
        backendId: id,
      );
    }
    return UnknownStoreException(debugDetail: e.message, backendId: id);
  }
}
