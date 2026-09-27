/// [BackendAppimage]: the AppImage backend — file-based, no daemon.
///
/// All outside-world contact goes through [AppImageTransport]; tests
/// script a stub. Error mapping lives here so every failure surfaces
/// as a typed [StoreException]. Identity is the file's sha256
/// (content-addressed, stable across moves/renames/copies); the
/// install-copy keeps the source's identity.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:store_contracts/store_contracts.dart';

import 'handle.dart';
import 'identity.dart';
import 'metadata.dart';
import 'transport.dart';

/// Scan roots, in order (research §2 — appimaged's monitored dirs).
List<String> _scanDirs(String home) => [
  '$home/Applications',
  '$home/.local/bin',
  '$home/bin',
  '$home/Downloads',
  '/opt',
  '/usr/local/bin',
  '/Applications',
];

/// Honest unsandboxed disclosure, prefixed to every description
/// (AppImage is unsandboxed by design — LLD §6).
const _unsandboxedDisclosure =
    "Runs unsandboxed with your user's full privileges. ";

/// Record of what install() created — remove() reverses exactly this.
/// Stored at `~/.local/share/libreapp-center/appimage/<sha>.json`.
class InstallManifest {
  const InstallManifest({
    required this.sourcePath,
    required this.managedPath,
    required this.copied,
    required this.desktopFile,
    this.iconPath,
  });

  final String sourcePath;
  final String managedPath;

  /// True when install() copied the file into `~/Applications`;
  /// false when it integrated the user's file in place.
  final bool copied;
  final String desktopFile;
  final String? iconPath;

  Map<String, dynamic> toJson() => {
    'sourcePath': sourcePath,
    'managedPath': managedPath,
    'copied': copied,
    'desktopFile': desktopFile,
    if (iconPath != null) 'iconPath': iconPath,
  };

  /// Null when the JSON isn't a manifest (corrupt → treated as absent).
  static InstallManifest? tryParse(Map<String, dynamic> json) {
    final sourcePath = json['sourcePath'];
    final managedPath = json['managedPath'];
    final copied = json['copied'];
    final desktopFile = json['desktopFile'];
    if (sourcePath is! String ||
        managedPath is! String ||
        copied is! bool ||
        desktopFile is! String) {
      return null;
    }
    final iconPath = json['iconPath'];
    return InstallManifest(
      sourcePath: sourcePath,
      managedPath: managedPath,
      copied: copied,
      desktopFile: desktopFile,
      iconPath: iconPath is String ? iconPath : null,
    );
  }
}

class BackendAppimage extends StoreBackend {
  BackendAppimage({required this.transport});

  final AppImageTransport transport;

  /// sha256 → indexed app, built by [_refreshIndex].
  Map<String, IndexedApp> _index = {};

  /// `'$path|$size|$mtimeMs'` → sha256; re-hash only when a file changed.
  final Map<String, String> _shaCache = {};

  String get _home => Platform.environment['HOME'] ?? '';

  String get _applicationsDir => '${_home}/Applications';
  String get _desktopDir => '${_home}/.local/share/applications';
  String get _stateDir => '${_home}/.local/share/libreapp-center/appimage';
  String get _iconDir => '${_home}/.cache/libreapp-center/appimage-icons';
  String get _metaDir => '${_home}/.cache/libreapp-center/appimage-meta';

  @override
  String get id => 'appimage';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {
    BackendCapability.search,
    BackendCapability.details,
    BackendCapability.install,
    BackendCapability.remove,
  };

  @override
  Future<bool> isAvailable() async {
    final home = _home;
    if (home.isEmpty) return false;
    try {
      await transport.listDir(home);
      return true;
    } on AppImageCommandException {
      return false;
    }
  }

  @override
  Stream<AppInfo> search(String query) {
    final controller = StreamController<AppInfo>();
    var cancelled = false;
    controller.onCancel = () {
      cancelled = true;
    };
    () async {
      try {
        await _refreshIndex(isCancelled: () => cancelled);
        if (!cancelled) {
          final q = query.toLowerCase();
          for (final entry in _index.entries) {
            if (cancelled) break;
            final app = entry.value;
            if (app.name.toLowerCase().contains(q) ||
                _basename(app.path).toLowerCase().contains(q)) {
              controller.add(_appInfo(entry.key, app, app.version));
            }
          }
        }
      } on AppImageCommandException catch (e) {
        if (!cancelled) controller.addError(_mapError(e));
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }();
    return controller.stream;
  }

  @override
  Future<AppDetails> getDetails(AppIdentity identity) async {
    final sha = identity.nativeId.toLowerCase();
    final entry = await _resolve(sha);
    final described = await _describe(entry);
    final name = described.desktop['Name'] ?? entry.name;
    final comment = described.desktop['Comment'];
    final version = described.version;
    return AppDetails(
      app: _appInfo(
        sha,
        entry,
        version,
        name: name,
        summary: comment ?? '',
        iconUrl: described.iconUrl,
      ),
      description: '$_unsandboxedDisclosure${comment ?? ''}',
      permissions: const [],
    );
  }

  @override
  Future<OperationHandle> install(AppIdentity identity) async {
    final sha = identity.nativeId.toLowerCase();
    final entry = await _resolve(sha);
    if (await _readManifest(sha) != null) {
      return AppimageOperationHandle.noop(
        app: identity,
        kind: OperationKind.install,
      );
    }
    return AppimageOperationHandle.run(
      app: identity,
      kind: OperationKind.install,
      body: (handle) => _doInstall(handle, entry),
    );
  }

  @override
  Future<OperationHandle> remove(AppIdentity identity) async {
    final sha = identity.nativeId.toLowerCase();
    final manifest = await _readManifest(sha);
    IndexedApp? entry;
    if (manifest == null) {
      try {
        entry = await _resolve(sha);
      } on AppNotFoundException {
        entry = null;
      }
    }
    if (manifest == null && entry == null) {
      throw AppNotFoundException(
        debugDetail: 'appimage $sha is not installed',
        backendId: id,
      );
    }
    return AppimageOperationHandle.run(
      app: identity,
      kind: OperationKind.remove,
      body: (handle) => _doRemove(handle, sha, manifest, entry),
    );
  }

  @override
  Future<OperationHandle> update(AppIdentity identity) {
    // Not advertised in [capabilities]: AppImage has no update mechanism
    // in MVP — no catalog, no bundled zsync engine (HLD §7). Calling it
    // is a contract violation by the caller; fail loudly and typed.
    throw UnknownStoreException(
      debugDetail: 'appimage backend does not support update()',
      backendId: id,
    );
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    // Honest []: no catalog to diff against, no bundled updater (HLD §7).
    return const [];
  }

  @override
  Future<List<AppInfo>> listInstalled() async {
    await _refreshIndex();
    return [
      for (final e in _index.entries) _appInfo(e.key, e.value, e.value.version),
    ];
  }

  @override
  Future<List<OperationHandle>> recoverInFlight() async {
    // File-copy installs are short; nothing to re-attach to (LLD §8).
    return const [];
  }

  /// The adopt/integrate flow (LLD §8): copy into `~/Applications`
  /// (unless already there), `chmod +x`, sha256-verify the copy, write
  /// the managed `.desktop` entry + icon + install manifest.
  /// `Preparing → Applying → Done`; cancel → partial work deleted →
  /// [Cancelled], never a bare [Failed].
  Future<OperationResult> _doInstall(
    AppimageOperationHandle handle,
    IndexedApp entry,
  ) async {
    handle.emit(const Preparing());
    handle.throwIfCancelled();
    final sha = entry.sha;
    final slug = slugify(entry.name);
    final inPlace = _isWithin(entry.path, _applicationsDir);
    final managedPath = inPlace
        ? entry.path
        : '$_applicationsDir/$slug.AppImage';
    final created = <String>[];
    try {
      handle.emit(const Applying());
      if (!inPlace) {
        await _guarded(() => transport.copyFile(entry.path, managedPath));
        created.add(managedPath);
        handle.throwIfCancelled();
        await _guarded(() => transport.chmodX(managedPath));
        handle.throwIfCancelled();
        final copySha = await _guarded(() => transport.sha256Of(managedPath));
        if (copySha.toLowerCase() != sha) {
          await _deleteQuietly(managedPath);
          throw VerificationException(
            debugDetail: 'appimage copy sha256 mismatch for $managedPath',
            expected: sha,
            actual: copySha,
            backendId: id,
          );
        }
      }
      handle.throwIfCancelled();
      final described = await _describe(entry);
      handle.throwIfCancelled();
      final desktopFile = 'appimage-$slug.desktop';
      final content = renderDesktopFile(
        name: described.desktop['Name'] ?? entry.name,
        comment: described.desktop['Comment'],
        execPath: managedPath,
        iconPath: described.iconUrl.isEmpty ? null : described.iconUrl,
        categories: described.desktop['Categories'],
        sha: sha,
      );
      await _guarded(
        () => transport.writeTextFile('$_desktopDir/$desktopFile', content),
      );
      created.add('$_desktopDir/$desktopFile');
      handle.throwIfCancelled();
      final manifest = InstallManifest(
        sourcePath: entry.path,
        managedPath: managedPath,
        copied: !inPlace,
        desktopFile: desktopFile,
        iconPath: described.iconUrl.isEmpty ? null : described.iconUrl,
      );
      await _guarded(
        () => transport.writeTextFile(
          '$_stateDir/$sha.json',
          jsonEncode(manifest.toJson()),
        ),
      );
      created.add('$_stateDir/$sha.json');
      handle.throwIfCancelled();
      return OperationResult(installedVersion: described.version);
    } on AppimageOperationCancelled {
      // Roll back everything this run created: Cancelled means the
      // system is unchanged.
      for (final p in created.reversed) {
        await _deleteQuietly(p);
      }
      rethrow;
    }
  }

  /// Reverse exactly what the manifest records. A copy we made is
  /// deleted; the user's original file is never touched (LLD §8).
  Future<OperationResult> _doRemove(
    AppimageOperationHandle handle,
    String sha,
    InstallManifest? manifest,
    IndexedApp? entry,
  ) async {
    handle.emit(const Preparing());
    handle.throwIfCancelled();
    handle.emit(const Applying());
    final desktopFile =
        manifest?.desktopFile ??
        'appimage-${slugify(entry?.name ?? sha)}.desktop';
    await _deleteQuietly('$_desktopDir/$desktopFile');
    handle.throwIfCancelled();
    final iconPath = manifest?.iconPath;
    if (iconPath != null) {
      await _deleteQuietly(iconPath);
    } else {
      // Best-effort de-integration: cached icon under either extension.
      await _deleteQuietly('$_iconDir/$sha.png');
      await _deleteQuietly('$_iconDir/$sha.svg');
    }
    await _deleteQuietly('$_stateDir/$sha.json');
    handle.throwIfCancelled();
    if (manifest != null && manifest.copied) {
      await _guarded(() => transport.deleteFile(manifest.managedPath));
    }
    return const OperationResult();
  }

  /// Lazy full metadata: cached `.desktop` (keyed by sha) or extract,
  /// then cached icon. Extraction failures fall back to filename
  /// heuristics (LLD §7) — never a throw.
  Future<_DescribedApp> _describe(IndexedApp entry) async {
    final desktop =
        await _cachedDesktop(entry.sha) ?? await _extractDesktop(entry);
    final iconName = desktop['Icon'];
    var iconUrl = '';
    if (iconName != null && iconName.isNotEmpty) {
      iconUrl = await _cachedOrExtractIcon(entry, iconName);
    }
    return _DescribedApp(
      desktop: desktop,
      iconUrl: iconUrl,
      version: versionFallback(
        xAppImageVersion: desktop['X-AppImage-Version'],
        desktopVersion: desktop['Version'],
        filenameVersion: entry.version,
      ),
    );
  }

  Future<Map<String, String>?> _cachedDesktop(String sha) async {
    try {
      final bytes = await transport.readHead('$_metaDir/$sha.desktop', 65536);
      return parseDesktopFile(utf8.decode(bytes));
    } on AppImageCommandException {
      return null; // not cached — extract
    } on FormatException {
      return null; // corrupt cache entry — re-extract
    }
  }

  Future<Map<String, String>> _extractDesktop(IndexedApp entry) async {
    String? extracted;
    try {
      extracted = await transport.extractDesktop(entry.path, _metaDir);
    } on AppImageCommandException {
      return const {};
    }
    if (extracted == null) return const {};
    final target = '$_metaDir/${entry.sha}.desktop';
    try {
      if (extracted != target) {
        await transport.copyFile(extracted, target);
        await transport.deleteFile(extracted);
      }
      final bytes = await transport.readHead(target, 65536);
      return parseDesktopFile(utf8.decode(bytes));
    } on AppImageCommandException {
      return const {};
    } on FormatException {
      return const {};
    }
  }

  Future<String> _cachedOrExtractIcon(IndexedApp entry, String iconName) async {
    for (final ext in ['.png', '.svg']) {
      final cached = '$_iconDir/${entry.sha}$ext';
      try {
        await transport.readHead(cached, 16);
        return cached;
      } on AppImageCommandException {
        // not cached under this extension — try the next
      }
    }
    String? extracted;
    try {
      extracted = await transport.extractIcon(
        entry.path,
        _iconDir,
        iconName: iconName,
      );
    } on AppImageCommandException {
      return '';
    }
    if (extracted == null) return '';
    final target = '$_iconDir/${entry.sha}${_extensionOf(extracted)}';
    try {
      if (extracted != target) {
        await transport.copyFile(extracted, target);
        await transport.deleteFile(extracted);
      }
      return target;
    } on AppImageCommandException {
      return '';
    }
  }

  Future<IndexedApp> _resolve(String sha) async {
    var entry = _index[sha];
    if (entry == null) {
      await _refreshIndex();
      entry = _index[sha];
    }
    if (entry == null) {
      throw AppNotFoundException(
        debugDetail: 'appimage $sha not found in scan',
        backendId: id,
      );
    }
    return entry;
  }

  /// Non-recursive scan of the scan roots: prefilter by extension /
  /// executable bit (cheap), decide by ELF + `AI\x01`/`AI\x02` magic
  /// (never the extension alone). Missing/unreadable dirs and files
  /// are skipped — normal conditions, not errors.
  Future<void> _refreshIndex({bool Function()? isCancelled}) async {
    final next = <String, IndexedApp>{};
    final shaCache = <String, String>{};
    for (final dir in _scanDirs(_home)) {
      if (isCancelled?.call() ?? false) break;
      late final List<DirEntry> entries;
      try {
        entries = await transport.listDir(dir);
      } on AppImageCommandException {
        continue;
      }
      for (final e in entries) {
        if (!e.isFile) continue;
        final lower = e.name.toLowerCase();
        if (!lower.endsWith('.appimage') && !e.isExecutable) continue;
        late final List<int> head;
        try {
          head = await transport.readHead(e.path, 16);
        } on AppImageCommandException {
          continue;
        }
        if (!isAppImageMagic(head)) continue;
        final key = indexCacheKey(e.path, e.size, e.mtimeMs);
        var sha = _shaCache[key] ?? shaCache[key];
        if (sha == null) {
          try {
            sha = (await transport.sha256Of(e.path)).toLowerCase();
          } on AppImageCommandException {
            continue;
          }
        }
        shaCache[key] = sha;
        final meta = parseFilename(e.name);
        next[sha] = IndexedApp(
          sha: sha,
          path: e.path,
          size: e.size,
          mtimeMs: e.mtimeMs,
          name: meta.name,
          version: meta.version,
        );
      }
    }
    _index = next;
    _shaCache
      ..clear()
      ..addAll(shaCache);
  }

  Future<InstallManifest?> _readManifest(String sha) async {
    late final List<int> bytes;
    try {
      bytes = await transport.readHead('$_stateDir/$sha.json', 65536);
    } on AppImageCommandException {
      return null; // no manifest — not installed through us
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      return InstallManifest.tryParse(decoded);
    } on FormatException {
      return null; // corrupt manifest — treat as absent (best effort)
    }
  }

  AppInfo _appInfo(
    String sha,
    IndexedApp entry,
    String? version, {
    String? name,
    String? summary,
    String iconUrl = '',
  }) {
    final v = version ?? entry.version;
    return AppInfo(
      identity: AppIdentity(backendId: id, nativeId: sha),
      name: name ?? entry.name,
      summary: summary ?? '',
      iconUrl: iconUrl,
      source: AppSource.appImage,
      version: v,
      // Every scanned file is installed by definition → isInstalled == true.
      installedVersion: v ?? 'unknown',
    );
  }

  bool _isWithin(String path, String dir) =>
      path == dir || path.startsWith('$dir/');

  Future<T> _guarded<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on AppImageCommandException catch (e) {
      throw _mapError(e);
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await transport.deleteFile(path);
    } on AppImageCommandException {
      // best effort — cleanup must never fail an operation
    }
  }

  StoreException _mapError(AppImageCommandException e) {
    final err = e.stderr.toLowerCase();
    if (e.exitCode == 127 || err.contains('command not found')) {
      return BackendUnavailableException(
        debugDetail: 'appimage helper missing: ${e.args.first}',
        backendId: id,
      );
    }
    if (err.contains('no space left') ||
        err.contains('disk full') ||
        err.contains('enospc')) {
      return const DiskSpaceException(
        debugDetail: 'appimage: no space left on device',
        neededBytes: -1,
        availableBytes: 0,
        backendId: 'appimage',
      );
    }
    if (err.contains('permission denied') ||
        err.contains('operation not permitted') ||
        err.contains('eacces')) {
      return PermissionException(
        debugDetail: 'appimage: permission denied: ${e.stderr}',
        neededAccess: 'write access to ~/Applications and ~/.local/share',
        backendId: id,
      );
    }
    return UnknownStoreException(
      debugDetail: 'appimage ${e.args.join(' ')} exited ${e.exitCode}',
      rawOutput: e.stderr,
      backendId: id,
    );
  }
}

class _DescribedApp {
  const _DescribedApp({
    required this.desktop,
    required this.iconUrl,
    this.version,
  });

  final Map<String, String> desktop;
  final String iconUrl;
  final String? version;
}

String _basename(String path) {
  final idx = path.lastIndexOf('/');
  return idx < 0 ? path : path.substring(idx + 1);
}

/// Extension including the dot, lowercased; `.png` for extensionless files.
String _extensionOf(String path) {
  final base = _basename(path);
  final idx = base.lastIndexOf('.');
  if (idx <= 0) return '.png';
  return base.substring(idx).toLowerCase();
}
