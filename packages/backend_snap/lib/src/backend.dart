/// [BackendSnap]: the snap backend, over the snapd change API.
///
/// Install/remove/refresh return a change id; the handle polls the
/// change and maps snapd task progress onto operation states.
/// Permissions surface the snap's confinement pre-install (ADR-009):
/// a classic snap's "full system access" is visible before the user
/// commits, not after.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'handle.dart';
import 'transport.dart';

class BackendSnap extends StoreBackend {
  BackendSnap({required this.transport});

  final SnapdTransport transport;

  @override
  String get id => 'snap';

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
      await transport.checkAvailable();
      return true;
    } on SnapdTransportException {
      return false;
    }
  }

  @override
  Stream<AppInfo> search(String query) {
    final controller = StreamController<AppInfo>();
    var cancelled = false;
    // snapd find is one HTTP round-trip: cancelling the subscription
    // abandons the result, which is the honest bound of "stop work".
    controller.onCancel = () => cancelled = true;
    () async {
      try {
        final snaps = await transport.find(query);
        for (final s in snaps) {
          if (cancelled || controller.isClosed) break;
          controller.add(_toAppInfo(s));
        }
      } catch (e) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(
            e is SnapdTransportException
                ? _mapError(e)
                : UnknownStoreException(
                    debugDetail: 'snap search failed: $e',
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

  AppInfo _toAppInfo(SnapSummaryData s) => AppInfo(
    identity: AppIdentity(backendId: id, nativeId: s.name),
    name: s.title.isEmpty ? s.name : s.title,
    summary: s.summary,
    iconUrl: s.iconUrl,
    source: AppSource.snap,
    version: s.version.isEmpty ? null : s.version,
    installedVersion: s.installedVersion,
  );

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    late final SnapSummaryData s;
    try {
      s = await transport.getDetails(id.nativeId);
    } on SnapdNotFoundException catch (e) {
      throw AppNotFoundException(debugDetail: e.message, backendId: this.id);
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    return AppDetails(
      app: _toAppInfo(s),
      description: s.description,
      permissions: _permissionsFor(s.confinement),
    );
  }

  /// Confinement is knowable pre-install from the store metadata —
  /// the one permission signal snaps honestly offer up front.
  List<Permission> _permissionsFor(String confinement) {
    switch (confinement) {
      case 'classic':
        return const [
          Permission(
            id: 'confinement-classic',
            label: 'Classic confinement — full system access',
          ),
        ];
      case 'devmode':
        return const [
          Permission(
            id: 'confinement-devmode',
            label: 'Development mode — unsandboxed',
          ),
        ];
      default:
        return const [
          Permission(
            id: 'confinement-strict',
            label: 'Sandboxed (strict confinement)',
          ),
        ];
    }
  }

  Future<bool> _isInstalled(String name) async {
    try {
      return (await transport.installedNames()).contains(name);
    } on SnapdTransportException {
      return false;
    }
  }

  @override
  Future<OperationHandle> install(AppIdentity app) async {
    if (await _isInstalled(app.nativeId)) {
      return SnapOperationHandle.noop(app: app, kind: OperationKind.install);
    }
    late final bool classic;
    try {
      classic =
          (await transport.getDetails(app.nativeId)).confinement == 'classic';
    } on SnapdNotFoundException catch (e) {
      throw AppNotFoundException(debugDetail: e.message, backendId: id);
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    late final String changeId;
    try {
      changeId = await transport.install(app.nativeId, classic: classic);
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    return SnapOperationHandle(
      app: app,
      kind: OperationKind.install,
      transport: transport,
      changeId: changeId,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> remove(AppIdentity app) async {
    late final String changeId;
    try {
      changeId = await transport.remove(app.nativeId);
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    return SnapOperationHandle(
      app: app,
      kind: OperationKind.remove,
      transport: transport,
      changeId: changeId,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> update(AppIdentity app) async {
    late final String changeId;
    try {
      changeId = await transport.refresh(app.nativeId);
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    return SnapOperationHandle(
      app: app,
      kind: OperationKind.update,
      transport: transport,
      changeId: changeId,
      mapError: _mapError,
    );
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    late final List<SnapSummaryData> snaps;
    try {
      snaps = await transport.updatesAvailable();
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    return [
      for (final s in snaps)
        UpdateInfo(
          identity: AppIdentity(backendId: id, nativeId: s.name),
          name: s.title.isEmpty ? s.name : s.title,
          fromVersion: s.installedVersion,
          toVersion: s.version.isEmpty ? null : s.version,
        ),
    ];
  }

  @override
  Future<List<AppInfo>> listInstalled() async {
    late final List<String> names;
    try {
      names = await transport.installedNames();
    } on SnapdTransportException catch (e) {
      throw _mapError(e);
    }
    // N+1 getDetails is the honest MVP: the transport contract exposes
    // only names, and installed sets are small. A bulk `installedSnaps()`
    // transport call would collapse this to one round-trip.
    final apps = <AppInfo>[];
    for (final name in names) {
      late final SnapSummaryData s;
      try {
        s = await transport.getDetails(name);
      } on SnapdNotFoundException {
        // Removed between installedNames() and getDetails(): skip the
        // entry rather than failing the whole enumeration.
        continue;
      } on SnapdTransportException catch (e) {
        throw _mapError(e);
      }
      apps.add(_installedAppInfo(s));
    }
    return apps;
  }

  /// Maps a snap known to be installed. The snapd getSnap response
  /// carries no installedVersion field, so a null falls back to the
  /// snap's own version — for a local snap that IS the installed one.
  /// [AppInfo.isInstalled] must be true for every entry this returns.
  AppInfo _installedAppInfo(SnapSummaryData s) {
    final info = _toAppInfo(s);
    if (info.installedVersion != null) return info;
    return AppInfo(
      identity: info.identity,
      name: info.name,
      summary: info.summary,
      iconUrl: info.iconUrl,
      source: info.source,
      version: info.version,
      installedVersion: info.version ?? 'unknown',
    );
  }

  @override
  Future<List<OperationHandle>> recoverInFlight() async {
    late final List<SnapdChangeSnapshot> changes;
    try {
      changes = await transport.inProgressChanges();
    } on SnapdTransportException {
      return const [];
    }
    final handles = <OperationHandle>[];
    for (final c in changes) {
      if (c.snapNames.isEmpty) continue;
      final kind = switch (c.kind) {
        'install' => OperationKind.install,
        'remove' => OperationKind.remove,
        'refresh' => OperationKind.update,
        _ => null,
      };
      if (kind == null) continue;
      handles.add(
        SnapOperationHandle.attached(
          app: AppIdentity(backendId: id, nativeId: c.snapNames.first),
          kind: kind,
          transport: transport,
          changeId: c.id,
          mapError: _mapError,
        ),
      );
    }
    return handles;
  }

  StoreException _mapError(SnapdTransportException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('no such file') || msg.contains('connection refused')) {
      return BackendUnavailableException(
        debugDetail: 'snapd unreachable: ${e.message}',
        backendId: id,
      );
    }
    if (msg.contains('not found') ||
        msg.contains('no snap') ||
        msg.contains('not installed')) {
      return AppNotFoundException(debugDetail: e.message, backendId: id);
    }
    if (msg.contains('no space') || msg.contains('disk full')) {
      return const DiskSpaceException(
        debugDetail: 'snapd reported no space left',
        neededBytes: -1,
        availableBytes: 0,
        backendId: 'snap',
      );
    }
    if (msg.contains('network') ||
        msg.contains('timeout') ||
        msg.contains('connection')) {
      return NetworkException(debugDetail: e.message, backendId: id);
    }
    if (msg.contains('permission') ||
        msg.contains('access denied') ||
        msg.contains('unauthorized')) {
      return PermissionException(
        debugDetail: e.message,
        neededAccess: 'snapd system action access',
        backendId: id,
      );
    }
    return UnknownStoreException(debugDetail: e.message, backendId: id);
  }
}
