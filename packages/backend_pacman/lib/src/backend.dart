/// [BackendPacman]: the pacman backend, over the `pacman(1)` CLI
/// subprocess (Arch-like systems).
///
/// Mutating calls spawn `pkexec pacman …` whose line-classified events
/// [PacmanOperationHandle] maps onto the operation states. Card
/// identity is the package name alone — alpm's local db is name-keyed
/// (research §3). Every result is labeled [AppSource.pacman], never
/// deb (research D10).
///
/// Permissions surface the one honest pre-install signal pacman
/// offers (ADR-009): pacman packages are **unsandboxed** — full
/// system access. That is the truth, not a weakness to hide.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'handle.dart';
import 'identity.dart';
import 'metadata.dart';
import 'transport.dart';

class BackendPacman extends StoreBackend {
  BackendPacman({required this.transport});

  final PacmanTransport transport;

  @override
  String get id => 'pacman';

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
      // The contract budgets 200ms: `pacman --version` is a cheap
      // local exec. Never throws.
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
    // Killing the `pacman -Ss` child is the honest bound of "stop
    // work" (the 500ms contract rule, HLD §3).
    controller.onCancel = () {
      cancelled = true;
      unawaited(transport.cancelSearch());
    };
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
            e is PacmanTransportException
                ? _mapError(e)
                : UnknownStoreException(
                    debugDetail: 'pacman search failed: $e',
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

  AppInfo _toAppInfo(PacmanPackageData p) => AppInfo(
    identity: AppIdentity(backendId: id, nativeId: p.id),
    name: p.name,
    summary: p.summary,
    iconUrl: '', // no icons on pacman's CLI surface (HLD §2)
    source: AppSource.pacman, // NEVER deb (research D10)
    version: displayVersion(p.version),
    installedVersion: p.installed ? (p.installedVersion ?? p.version) : null,
  );

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    // A corrupt stored id is "not found", never a crash (LLD §6).
    try {
      parsePackageId(id.nativeId);
    } on FormatException catch (e) {
      throw AppNotFoundException(
        debugDetail: 'corrupt pacman package id: $e',
        backendId: this.id,
      );
    }
    late final PacmanPackageData p;
    try {
      p = await transport.getDetails(id.nativeId);
    } on PacmanNotFoundException catch (e) {
      throw AppNotFoundException(debugDetail: e.stderr, backendId: this.id);
    } on PacmanTransportException catch (e) {
      throw _mapError(e);
    }
    return AppDetails(
      app: _toAppInfo(p),
      description:
          '${p.description.isEmpty ? p.summary : p.description}\n\n$unsandboxedDisclosure',
      permissions: _pacmanPermissions,
      license: p.license.isEmpty ? null : p.license,
      homepage: p.url.isEmpty ? null : p.url,
    );
  }

  /// pacman packages run unsandboxed. Say it up front — in the
  /// permission list and appended to the description (LLD §6).
  static const List<Permission> _pacmanPermissions = [
    Permission(
      id: 'confinement-none',
      label: 'Unsandboxed — full system access',
    ),
  ];

  static const String unsandboxedDisclosure =
      'Pacman packages run unsandboxed with full system access.';

  /// Parse [nativeId], mapping a corrupt id to a typed not-found
  /// (never a raw FormatException escaping the backend).
  PacmanPackageId _parseIdOrThrow(String nativeId) {
    try {
      return parsePackageId(nativeId);
    } on FormatException catch (e) {
      throw AppNotFoundException(
        debugDetail: 'corrupt pacman package id: $e',
        backendId: id,
      );
    }
  }

  /// The noop-check primitive: `pacman -Q -- <name>`.
  Future<bool> _isInstalledName(String name) async {
    try {
      return await transport.isInstalled(name);
    } on PacmanTransportException {
      return false;
    }
  }

  Future<PacmanTransaction> _begin(
    Future<PacmanTransaction> Function() start,
  ) async {
    try {
      return await start();
    } on PacmanTransportException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<OperationHandle> install(AppIdentity app) async {
    final pid = _parseIdOrThrow(app.nativeId);
    // Contract §6 prefers the cheap noop: --needed on the child is
    // belt-and-braces.
    if (await _isInstalledName(pid.name)) {
      return PacmanOperationHandle.noop(app: app, kind: OperationKind.install);
    }
    final tx = await _begin(() => transport.install(app.nativeId));
    return PacmanOperationHandle(
      app: app,
      kind: OperationKind.install,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> remove(AppIdentity app) async {
    final pid = _parseIdOrThrow(app.nativeId);
    if (!await _isInstalledName(pid.name)) {
      return PacmanOperationHandle.noop(app: app, kind: OperationKind.remove);
    }
    final tx = await _begin(() => transport.remove(app.nativeId));
    return PacmanOperationHandle(
      app: app,
      kind: OperationKind.remove,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> update(AppIdentity app) async {
    final pid = _parseIdOrThrow(app.nativeId);
    late final List<PacmanPackageData> updates;
    try {
      updates = await transport.updatesAvailable();
    } on PacmanTransportException catch (e) {
      throw _mapError(e);
    }
    if (!updates.any((u) => u.name == pid.name)) {
      return PacmanOperationHandle.noop(app: app, kind: OperationKind.update);
    }
    final tx = await _begin(() => transport.update(app.nativeId));
    return PacmanOperationHandle(
      app: app,
      kind: OperationKind.update,
      transaction: tx,
      mapError: _mapError,
    );
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    late final List<PacmanPackageData> packages;
    try {
      packages = await transport.updatesAvailable();
    } on PacmanTransportException catch (e) {
      throw _mapError(e);
    }
    return [
      for (final p in packages)
        UpdateInfo(
          identity: AppIdentity(backendId: id, nativeId: p.id),
          name: p.name,
          fromVersion: p.installedVersion,
          toVersion: displayVersion(p.version),
        ),
    ];
  }

  @override
  Future<List<AppInfo>> listInstalled() async {
    // Bulk: exactly ONE `pacman -Q` invocation (research D3) — there
    // is no N+1 legacy path. Unparseable lines are skipped by the
    // transport (partial results); a failed invocation is a real,
    // typed error.
    try {
      final packages = await transport.installedPackages();
      return [for (final p in packages) _toAppInfo(p)];
    } on PacmanTransportException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<List<OperationHandle>> recoverInFlight() async {
    // pacman has no in-flight transaction journal the backend could
    // re-attach to (no snapd-like `Doing` query). Returning [] is
    // honest; the exam tolerates empty.
    return const [];
  }

  /// Dependency-error detail lines: pacman prints
  /// `:: installing <x> breaks dependency '<dep>' required by <y>`.
  /// Collect the quoted dependency names for the typed error.
  static List<String> _dependencyDetails(String stderr) {
    final quoted = RegExp(r"'([^']+)'");
    final details = <String>[];
    for (final line in stderr.split('\n')) {
      if (!line.toLowerCase().contains('depend')) continue;
      for (final m in quoted.allMatches(line)) {
        details.add(m.group(1)!);
      }
    }
    return details;
  }

  StoreException _mapError(PacmanTransportException e) {
    if (e is PacmanNotFoundException) {
      return AppNotFoundException(debugDetail: e.stderr, backendId: id);
    }
    // Binary-missing disambiguation (the transport names the binary):
    // a missing pacman on the read path is "backend unavailable";
    // a missing pkexec on the mutate path is a polkit problem.
    if (e.stderr.contains('pacman not found')) {
      return BackendUnavailableException(debugDetail: e.stderr, backendId: id);
    }
    if (e.stderr.contains('pkexec not found')) {
      return PermissionException(
        debugDetail: e.stderr,
        neededAccess:
            'polkit (pkexec) for privileged pacman operations — install '
            'polkit and use a session with an authentication agent',
        backendId: id,
      );
    }
    final msg = e.stderr.toLowerCase();
    if (msg.contains('you cannot perform this operation unless you are root')) {
      // Defense-in-depth: should not happen when pkexec worked.
      return PermissionException(
        debugDetail: e.stderr,
        neededAccess: 'root via pkexec (polkit)',
        backendId: id,
      );
    }
    if (msg.contains('target not found:') || msg.contains('was not found')) {
      return AppNotFoundException(debugDetail: e.stderr, backendId: id);
    }
    if (msg.contains('could not satisfy dependencies')) {
      return DependencyException(
        debugDetail: e.stderr,
        details: _dependencyDetails(e.stderr),
        backendId: id,
      );
    }
    if (msg.contains('conflicting files')) {
      return ConflictException(debugDetail: e.stderr, backendId: id);
    }
    if (msg.contains('unable to lock database') ||
        msg.contains('could not lock database')) {
      // Retryable manually, never auto: the db lock serializes pacman.
      return ConflictException(
        debugDetail: 'pacman db locked by another process',
        backendId: id,
      );
    }
    if (msg.contains('cannot fetch updates') ||
        msg.contains('failed retrieving file') ||
        msg.contains('failed to synchronize') ||
        msg.contains('could not resolve host')) {
      return NetworkException(debugDetail: e.stderr, backendId: id);
    }
    if (msg.contains('too full') || msg.contains('not enough disk space')) {
      // pacman does not report byte counts here (rpm precedent).
      return DiskSpaceException(
        debugDetail: e.stderr,
        neededBytes: -1,
        availableBytes: 0,
        backendId: id,
      );
    }
    if ((msg.contains('signature') && msg.contains('is invalid')) ||
        msg.contains('invalid or corrupted package')) {
      return VerificationException(debugDetail: e.stderr, backendId: id);
    }
    return UnknownStoreException(debugDetail: e.stderr, backendId: id);
  }
}
