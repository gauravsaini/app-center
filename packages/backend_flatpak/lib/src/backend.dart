/// [BackendFlatpak]: the CLI-wrapper Flatpak backend (ADR-006).
///
/// All outside-world contact goes through [FlatpakTransport]; tests
/// script a stub. Error mapping lives here so every failure surfaces
/// as a typed [StoreException].
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

import 'handle.dart';
import 'ref.dart';
import 'transport.dart';

/// Human labels for well-known flatpak permission keys
/// (`flatpak info --show-permissions`). Unknown keys surface raw —
/// never dropped silently.
const _permissionLabels = {
  'shared=network': 'Network access',
  'shared=ipc': 'Inter-process communication',
  'sockets=x11': 'Display server (X11)',
  'sockets=wayland': 'Display server (Wayland)',
  'sockets=pulseaudio': 'Audio playback',
  'sockets=session-bus': 'Session bus access',
  'sockets=system-bus': 'System bus access',
  'devices=dri': 'GPU acceleration',
  'devices=all': 'All devices',
  'filesystems=home': 'Home folder access',
  'filesystems=host': 'Full filesystem access',
};

final _appIdRe = RegExp(r'^([A-Za-z0-9_]+[.-])+[A-Za-z0-9_]+$');

class BackendFlatpak extends StoreBackend {
  BackendFlatpak({required this.transport, this.remote = 'flathub'});

  final FlatpakTransport transport;

  /// Which remote to install from / query. Default flathub.
  final String remote;

  @override
  String get id => 'flatpak';

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
      final lines = await transport.run(['--version']);
      return lines.isNotEmpty && lines.first.startsWith('Flatpak ');
    } on FlatpakCommandException {
      return false;
    }
  }

  @override
  Stream<AppInfo> search(String query) {
    final controller = StreamController<AppInfo>();
    FlatpakProcess? proc;
    var done = false;
    controller.onCancel = () async {
      done = true;
      await proc?.terminate();
    };
    () async {
      try {
        proc = transport.spawn(['search', query]);
        await for (final line in proc!.stdoutLines) {
          if (done) break;
          final app = _parseSearchLine(line);
          if (app != null) controller.add(app);
        }
        if (!done) {
          final code = await proc!.exitCode;
          if (code != 0) {
            controller.addError(
              _mapError(FlatpakCommandException(['search', query], code, '')),
            );
          }
        }
      } catch (e) {
        if (!done) {
          controller.addError(
            e is StoreException
                ? e
                : UnknownStoreException(
                    debugDetail: 'flatpak search failed: $e',
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

  /// Heuristic parse of one `flatpak search` table row.
  /// The app id is the token shaped like a reverse-DNS id; the name is
  /// the leading tokens, the description what's between. Documented as
  /// heuristic — the table layout is not a stable API.
  AppInfo? _parseSearchLine(String line) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('Name\t') || t.startsWith('Name ')) {
      return null;
    }
    final tokens = t
        .split(RegExp(r'\s{2,}|\t'))
        .where((s) => s.isNotEmpty)
        .toList();
    final words = tokens.length == 1 ? t.split(RegExp(r'\s+')) : tokens;
    final idIdx = words.indexWhere((w) => _appIdRe.hasMatch(w));
    if (idIdx < 0) return null;
    final appId = words[idIdx];
    final name = idIdx > 0 ? words.sublist(0, 1).join(' ') : appId;
    return AppInfo(
      identity: AppIdentity(backendId: id, nativeId: appId),
      name: name,
      summary: '',
      iconUrl: '',
      source: AppSource.flatpak,
    );
  }

  @override
  Future<AppDetails> getDetails(AppIdentity id) async {
    final ref = FlatpakRef.parse(id.nativeId);
    Map<String, String> fields;
    var installed = false;
    try {
      fields = _parseKeyValues(await transport.run(['info', ref.ref]));
      installed = true;
    } on FlatpakCommandException {
      try {
        fields = _parseKeyValues(
          await transport.run(['remote-info', remote, ref.ref]),
        );
      } on FlatpakCommandException catch (e) {
        throw _mapError(e);
      }
    }
    final permissions = installed
        ? await _permissions(ref)
        : const <Permission>[];
    final app = AppInfo(
      identity: id,
      name: fields['Name'] ?? fields['Title'] ?? ref.id,
      summary: fields['Summary'] ?? '',
      iconUrl: '',
      source: AppSource.flatpak,
      version: fields['Version'],
      installedVersion: installed ? fields['Version'] : null,
    );
    return AppDetails(
      app: app,
      description: fields['Description'] ?? fields['Summary'] ?? '',
      permissions: permissions,
    );
  }

  Future<List<Permission>> _permissions(FlatpakRef ref) async {
    late final List<String> lines;
    try {
      lines = await transport.run(['info', '--show-permissions', ref.ref]);
    } on FlatpakCommandException {
      return const [];
    }
    final out = <Permission>[];
    for (final line in lines) {
      // Lines look like: shared=network;ipc;  sockets=x11;wayland;
      for (final part in line.split(';')) {
        final kv = part.trim();
        if (!kv.contains('=')) continue;
        final label = _permissionLabels[kv] ?? kv;
        out.add(Permission(id: kv, label: label));
      }
    }
    return out;
  }

  Map<String, String> _parseKeyValues(List<String> lines) {
    final map = <String, String>{};
    for (final line in lines) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
    return map;
  }

  Future<bool> _isInstalled(FlatpakRef ref) async {
    try {
      await transport.run(['info', ref.ref]);
      return true;
    } on FlatpakCommandException {
      return false;
    }
  }

  @override
  Future<OperationHandle> install(AppIdentity app) async {
    final ref = FlatpakRef.parse(app.nativeId);
    if (await _isInstalled(ref)) {
      return FlatpakOperationHandle.noop(app: app, kind: OperationKind.install);
    }
    final proc = transport.spawn([
      'install',
      '-y',
      '--noninteractive',
      remote,
      ref.ref,
    ]);
    return FlatpakOperationHandle(
      app: app,
      kind: OperationKind.install,
      process: proc,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> remove(AppIdentity app) async {
    final ref = FlatpakRef.parse(app.nativeId);
    final proc = transport.spawn(['uninstall', '-y', ref.ref]);
    return FlatpakOperationHandle(
      app: app,
      kind: OperationKind.remove,
      process: proc,
      mapError: _mapError,
    );
  }

  @override
  Future<OperationHandle> update(AppIdentity app) async {
    final ref = FlatpakRef.parse(app.nativeId);
    final proc = transport.spawn(['update', '-y', ref.ref]);
    return FlatpakOperationHandle(
      app: app,
      kind: OperationKind.update,
      process: proc,
      mapError: _mapError,
    );
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    // v1: not wired. `flatpak update` has no stable machine-readable
    // dry-run across versions; updates surface via update() on demand.
    // TODO(backend-flatpak): wire update discovery when the CLI offers
    // a stable interface.
    return const [];
  }

  @override
  Future<List<AppInfo>> listInstalled() async {
    late final List<String> lines;
    try {
      lines = await transport.run([
        'list',
        '--app',
        '--columns=application,name,version',
      ]);
    } on FlatpakCommandException catch (e) {
      throw _mapError(e);
    }
    // One CLI round-trip: unlike snap/deb this needs no N+1 follow-up.
    final apps = <AppInfo>[];
    for (final line in lines) {
      final app = _parseInstalledLine(line);
      if (app != null) apps.add(app);
    }
    return apps;
  }

  /// Parses one `flatpak list --app --columns=application,name,version`
  /// row. Columns are tab-separated; the application column is a
  /// reverse-DNS id, so a row without one is skipped (header or noise).
  /// Falls back to whitespace splitting when tabs are absent —
  /// documented as heuristic, like [_parseSearchLine]: the CLI table
  /// layout is not a stable API.
  AppInfo? _parseInstalledLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    final cols = t
        .split('\t')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (cols.length >= 3 && _appIdRe.hasMatch(cols[0])) {
      final version = cols[2];
      return _installedAppInfo(cols[0], cols[1], version);
    }
    // Whitespace fallback: column order is still
    // application,name,version — the id is the reverse-DNS token, the
    // version the last token, the name everything in between.
    final words = t.split(RegExp(r'\s+'));
    final idIdx = words.indexWhere((w) => _appIdRe.hasMatch(w));
    if (idIdx < 0) return null;
    final rest = words.sublist(idIdx + 1);
    final version = rest.isEmpty ? '' : rest.last;
    final name = rest.length > 1
        ? rest.sublist(0, rest.length - 1).join(' ')
        : words[idIdx];
    return _installedAppInfo(words[idIdx], name, version);
  }

  /// Builds the [AppInfo] for an installed flatpak. A row from
  /// `flatpak list` is installed by definition, so [AppInfo.isInstalled]
  /// must be true for every entry this returns.
  AppInfo _installedAppInfo(String appId, String name, String version) =>
      AppInfo(
        identity: AppIdentity(backendId: id, nativeId: appId),
        name: name.isEmpty ? appId : name,
        summary: '',
        iconUrl: '',
        source: AppSource.flatpak,
        version: version.isEmpty ? null : version,
        installedVersion: version.isEmpty ? 'unknown' : version,
      );

  @override
  Future<List<OperationHandle>> recoverInFlight() async {
    // A CLI wrapper cannot re-attach to processes from a previous
    // app lifetime. Documented limitation, not a silent failure.
    return const [];
  }

  StoreException _mapError(FlatpakCommandException e) {
    final err = e.stderr.toLowerCase();
    if (e.exitCode == 127 || err.contains('command not found')) {
      return BackendUnavailableException(
        debugDetail: 'flatpak binary not found (exit 127)',
        backendId: id,
      );
    }
    if (err.contains('no space left') || err.contains('disk full')) {
      return const DiskSpaceException(
        debugDetail: 'flatpak reported no space left',
        neededBytes: -1,
        availableBytes: 0,
        backendId: 'flatpak',
      );
    }
    if (err.contains('could not resolve') ||
        err.contains('connection refused') ||
        err.contains('network is unreachable') ||
        err.contains('offline') ||
        err.contains('timeout')) {
      return NetworkException(
        debugDetail: 'flatpak network failure: ${e.stderr}',
        backendId: id,
      );
    }
    if (err.contains('permission denied') ||
        err.contains('not allowed') ||
        err.contains('polkit')) {
      return PermissionException(
        debugDetail: 'flatpak permission failure: ${e.stderr}',
        neededAccess: 'flatpak system installation access',
        backendId: id,
      );
    }
    if (err.contains('no such ref') ||
        err.contains('not found') ||
        err.contains('no remote')) {
      return AppNotFoundException(
        debugDetail: 'flatpak ref not found: ${e.stderr}',
        backendId: id,
      );
    }
    return UnknownStoreException(
      debugDetail: 'flatpak exited ${e.exitCode}',
      rawOutput: e.stderr,
      backendId: id,
    );
  }
}
