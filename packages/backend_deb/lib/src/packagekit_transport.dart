/// [RealPackageKitTransport]: the real transport, over raw D-Bus
/// (`package:dbus`).
///
/// Why raw D-Bus instead of `package:packagekit`: the vendored 0.2.7
/// client parses every package-bearing signal through its strict 4-token
/// `PackageKitPackageId.fromString` *inside* the signal-stream `.map()` —
/// a 5-token ID throws there and the event never materializes
/// (docs/architecture/deb-packageid-fix.md §1). apt's PackageKit backend
/// emits 5-token IDs (`name;version;arch;origin;data` —
/// `backends/apt/apt-cache-file.cpp:483`, `lib/pk-package-id.c`), so the
/// vendored client cannot survive a single real transaction. This
/// transport therefore speaks the same
/// `org.freedesktop.PackageKit.Transaction` wire protocol the client
/// uses (method/signal signatures read from `packagekit` 0.2.7's
/// source), but decodes signals itself and parses IDs with
/// [DebPackageId.parse] at the seam. Method calls take verbatim ID
/// strings — the daemon accepts full 5-token IDs.
///
/// Nothing here is live-verified (no PackageKit/apt daemon in the
/// sandbox); every wire claim cites its source in comments.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';

import 'transport.dart';

/// A 5-token PackageKit package ID: `name;version;arch;origin;data`
/// (`lib/pk-package-id.c`: `pk_package_id_build`).
///
/// The version is carried **opaque** — never parsed or rebuilt — for the
/// same reason the rpm backend keeps its EVR opaque: any
/// parse/rebuild scheme is lossy.
class DebPackageId {
  const DebPackageId({
    required this.name,
    required this.version,
    required this.arch,
    required this.origin,
    required this.data,
  });

  final String name;

  /// Opaque version string (apt: `[epoch:]upstream[-revision]`).
  final String version;
  final String arch;
  final String origin;
  final String data;

  /// Throws [FormatException] unless exactly 5 tokens with a non-empty
  /// name. Never invents missing fields; never touches the version.
  factory DebPackageId.parse(String raw) {
    final t = raw.split(';');
    if (t.length != 5 || t[0].isEmpty) {
      throw FormatException('not a 5-token deb package id: $raw');
    }
    return DebPackageId(
      name: t[0],
      version: t[1],
      arch: t[2],
      origin: t[3],
      data: t[4],
    );
  }

  /// Verbatim round-trip: what the daemon emitted is what we send back.
  @override
  String toString() => '$name;$version;$arch;$origin;$data';
}

/// One decoded `Package` signal: `(info, package-id, summary)`.
///
/// The id is the daemon's verbatim string — unparsed. Parsing happens
/// in the mapping step so one corrupt id can be skipped without failing
/// the whole enumeration.
class DebRawPackage {
  const DebRawPackage({
    required this.installed,
    required this.id,
    required this.summary,
  });

  final bool installed;
  final String id;
  final String summary;
}

/// One decoded `Details` signal dict (`a{sv}`).
class DebRawDetails {
  const DebRawDetails({
    required this.id,
    this.summary = '',
    this.description = '',
    this.url = '',
  });

  final String id;
  final String summary;
  final String description;

  /// The `url` dict entry — the homepage signal (phase3-slice2.md §1).
  final String url;
}

class RealPackageKitTransport extends PackageKitTransport {
  /// Filter mask for the installed enumeration: `PackageKitFilter.installed`
  /// (enum order in packagekit 0.2.7: unknown=0, none=1, installed=2).
  static const int installedFilterMask = 1 << 2;

  RealPackageKitTransport();

  DBusClient? _bus;
  bool _connected = false;

  PackageKitTransportException _wrap(Object e) =>
      PackageKitTransportException(e.toString());

  Future<DBusClient> _connectedBus() async {
    if (_connected) return _bus!;
    try {
      // DBusClient connects lazily; the first method call proves the
      // daemon answers.
      final bus = DBusClient.system();
      _bus = bus;
      _connected = true;
      return bus;
    } catch (e) {
      throw _wrap(e);
    }
  }

  static const _busName = 'org.freedesktop.PackageKit';
  static const _rootPath = '/org/freedesktop/PackageKit';
  static const _pkInterface = 'org.freedesktop.PackageKit';
  static const _txInterface = 'org.freedesktop.PackageKit.Transaction';

  /// `PackageKitInfo.installed` (enum order in packagekit 0.2.7:
  /// unknown=0, installed=1, …).
  static const _infoInstalled = 1;

  Future<DBusObjectPath> _createTransaction(DBusClient bus) async {
    try {
      final root = DBusRemoteObject(
        bus,
        name: _busName,
        path: DBusObjectPath(_rootPath),
      );
      final result = await root
          .callMethod(
            _pkInterface,
            'CreateTransaction',
            const [],
            replySignature: DBusSignature('o'),
          )
          .timeout(const Duration(seconds: 5));
      return result.returnValues[0].asObjectPath();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<void> checkAvailable() async {
    final bus = await _connectedBus();
    // Probe: creating a transaction proves the daemon answers. The
    // probe is never given an action; the daemon reaps idle
    // transactions on its own.
    await _createTransaction(bus).timeout(const Duration(seconds: 2));
  }

  /// Runs [action] on a throwaway transaction, collecting `Package`
  /// signals until the transaction finishes. Throws
  /// [PackageKitTransportException] (never raw D-Bus errors) on failure.
  Future<List<DebRawPackage>> _packageEvents(
    Future<void> Function(DBusRemoteObject tx) action,
  ) async {
    final bus = await _connectedBus();
    final txPath = await _createTransaction(bus);
    final tx = DBusRemoteObject(bus, name: _busName, path: txPath);
    final packages = <DebRawPackage>[];
    final done = Completer<void>();
    final sub =
        DBusSignalStream(
          bus,
          sender: _busName,
          interface: _txInterface,
          path: txPath,
        ).listen((signal) {
          if (done.isCompleted) return;
          switch (signal.name) {
            case 'Package': // signature 'uss'
              if (signal.values.length == 3) {
                packages.add(
                  DebRawPackage(
                    installed: signal.values[0].asUint32() == _infoInstalled,
                    id: signal.values[1].asString(),
                    summary: signal.values[2].asString(),
                  ),
                );
              }
            case 'Finished': // 'uu'
            case 'Destroy': // ''
              done.complete();
          }
        });
    try {
      await action(tx);
      await done.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw PackageKitTransportException('packagekit query timed out');
    } catch (e) {
      throw _wrap(e);
    } finally {
      await sub.cancel();
    }
    return packages;
  }

  /// One batched `GetDetails` transaction; returns the raw `Details`
  /// dicts in arrival order.
  Future<List<DebRawDetails>> _detailsEvents(List<String> ids) async {
    final bus = await _connectedBus();
    final txPath = await _createTransaction(bus);
    final tx = DBusRemoteObject(bus, name: _busName, path: txPath);
    final details = <DebRawDetails>[];
    final done = Completer<void>();
    final sub =
        DBusSignalStream(
          bus,
          sender: _busName,
          interface: _txInterface,
          path: txPath,
        ).listen((signal) {
          if (done.isCompleted) return;
          switch (signal.name) {
            case 'Details': // 'a{sv}'
              final dict = signal.values[0].asStringVariantDict();
              details.add(
                DebRawDetails(
                  id: dict['package-id']?.asString() ?? '',
                  summary: dict['summary']?.asString() ?? '',
                  description: dict['description']?.asString() ?? '',
                  url: dict['url']?.asString() ?? '',
                ),
              );
            case 'Finished':
            case 'Destroy':
              done.complete();
          }
        });
    try {
      await tx.callMethod(_txInterface, 'GetDetails', [
        DBusArray.string(ids),
      ], replySignature: DBusSignature(''));
      await done.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw PackageKitTransportException('packagekit details timed out');
    } catch (e) {
      throw _wrap(e);
    } finally {
      await sub.cancel();
    }
    return details;
  }

  /// Parse [raw], or null when the daemon emitted an unparsable id
  /// (skipped, never fatal — deb-packageid-fix.md §2).
  static DebPackageId? _parseOrNull(String raw) {
    try {
      return DebPackageId.parse(raw);
    } on FormatException {
      return null;
    }
  }

  DebPackageData _mergeGroup(List<DebRawPackage> group) {
    // One card per package name: prefer the installed entry, else the
    // first candidate. No cross-version merging beyond that.
    final e = group.firstWhere((e) => e.installed, orElse: () => group.first);
    // Group members were parsed to build the group, so this cannot throw.
    final id = DebPackageId.parse(e.id);
    return DebPackageData(
      name: id.name,
      summary: e.summary,
      description: '',
      version: id.version,
      installedVersion: e.installed ? id.version : null,
    );
  }

  @override
  Future<List<DebPackageData>> search(String query) async {
    late final List<DebRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'SearchNames', [
          DBusUint64(0),
          DBusArray.string([query]),
        ], replySignature: DBusSignature('')),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final byName = <String, List<DebRawPackage>>{};
    for (final e in events) {
      final id = _parseOrNull(e.id);
      if (id == null) continue;
      (byName[id.name] ??= []).add(e);
    }
    return [for (final group in byName.values) _mergeGroup(group)];
  }

  Future<String> _resolvePackageId(
    String name, {
    required bool preferInstalled,
  }) async {
    late final List<DebRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'SearchNames', [
          DBusUint64(0),
          DBusArray.string([name]),
        ], replySignature: DBusSignature('')),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final exact = <DebRawPackage>[];
    for (final e in events) {
      final id = _parseOrNull(e.id);
      if (id != null && id.name == name) exact.add(e);
    }
    if (exact.isEmpty) {
      throw PackageKitNotFoundException('package "$name" not found');
    }
    int rank(DebRawPackage e) => e.installed ? 0 : 1;
    exact.sort(
      (a, b) => preferInstalled
          ? rank(a).compareTo(rank(b))
          : rank(b).compareTo(rank(a)),
    );
    // Verbatim id: the daemon resolves full 5-token IDs (research D4).
    return exact.first.id;
  }

  @override
  Future<DebPackageData> getDetails(String name) async {
    final id = await _resolvePackageId(name, preferInstalled: true);
    late final List<DebRawDetails> details;
    try {
      details = await _detailsEvents([id]);
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final d = details.isEmpty ? null : details.first;
    final parsed = _parseOrNull(id);
    return DebPackageData(
      name: parsed?.name ?? name,
      summary: d?.summary ?? '',
      description: d?.description ?? '',
      version: parsed?.version ?? '',
      installedVersion: null,
      url: d?.url ?? '',
    );
  }

  @override
  Future<List<String>> installedNames() async {
    late final List<DebRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'GetPackages', [
          DBusUint64(installedFilterMask),
        ], replySignature: DBusSignature('')),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final names = <String>[];
    for (final e in events) {
      final id = _parseOrNull(e.id);
      if (id != null) names.add(id.name);
    }
    return names;
  }

  /// Pure merge step of [installedPackages], kept static so tests can
  /// exercise the multi-arch dedupe without a D-Bus daemon.
  static List<DebPackageData> mergeInstalledPackages(
    List<DebRawPackage> packages,
    List<DebRawDetails> details,
  ) {
    final byName = <String, List<DebRawPackage>>{};
    for (final e in packages) {
      final id = _parseOrNull(e.id);
      if (id == null) continue;
      (byName[id.name] ??= []).add(e);
    }
    final detailsByName = <String, DebRawDetails>{};
    for (final d in details) {
      final id = _parseOrNull(d.id);
      if (id != null) detailsByName.putIfAbsent(id.name, () => d);
    }
    return [
      for (final group in byName.values)
        _mergeInstalledGroup(group, detailsByName),
    ];
  }

  static DebPackageData _mergeInstalledGroup(
    List<DebRawPackage> group,
    Map<String, DebRawDetails> detailsByName,
  ) {
    // One card per package name: prefer the installed entry's version,
    // else the first candidate — mirrors [_mergeGroup].
    final e = group.firstWhere((e) => e.installed, orElse: () => group.first);
    // The group is non-empty and every member parsed (they were parsed
    // to build the group), so this cannot throw.
    final id = DebPackageId.parse(e.id);
    final d = detailsByName[id.name];
    final detailSummary = d?.summary ?? '';
    return DebPackageData(
      name: id.name,
      summary: detailSummary.isEmpty ? e.summary : detailSummary,
      description: d?.description ?? '',
      version: id.version,
      installedVersion: e.installed ? id.version : null,
      url: d?.url ?? '',
    );
  }

  @override
  Future<List<DebPackageData>> installedPackages() async {
    late final List<DebRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'GetPackages', [
          DBusUint64(installedFilterMask),
        ], replySignature: DBusSignature('')),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    if (events.isEmpty) return const [];
    // Second (and last) transaction: descriptions for every installed
    // id. A batch failure throws PackageKitTransportException, which
    // propagates so the backend can fall back to the legacy path.
    // Verbatim ids: the daemon accepts full 5-token IDs.
    final ids = <String>[];
    for (final e in events) {
      if (_parseOrNull(e.id) != null) ids.add(e.id);
    }
    final details = await _detailsEvents(ids);
    return mergeInstalledPackages(events, details);
  }

  @override
  Future<List<DebPackageData>> updatesAvailable() async {
    late final List<DebRawPackage> updates;
    late final List<DebRawPackage> installed;
    try {
      updates = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'GetUpdates', [
          DBusUint64(0),
        ], replySignature: DBusSignature('')),
      );
      installed = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'GetPackages', [
          DBusUint64(installedFilterMask),
        ], replySignature: DBusSignature('')),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final installedByName = <String, String>{};
    for (final p in installed) {
      final id = _parseOrNull(p.id);
      if (id != null) installedByName.putIfAbsent(id.name, () => id.version);
    }
    final out = <DebPackageData>[];
    for (final u in updates) {
      final id = _parseOrNull(u.id);
      if (id == null) continue;
      out.add(
        DebPackageData(
          name: id.name,
          summary: u.summary,
          description: '',
          version: id.version,
          installedVersion: installedByName[id.name],
        ),
      );
    }
    return out;
  }

  /// PackageKit status indexes (packagekit 0.2.7 `PackageKitStatus`
  /// enum order): remove=6, download=8, install=9, update=10,
  /// signatureCheck=14, downloadRepository=20 … downloadUpdateInfo=25.
  DebTxStatus _mapStatus(int status) {
    switch (status) {
      case 8:
      case 20:
      case 21:
      case 22:
      case 23:
      case 24:
      case 25:
        return DebTxStatus.download;
      case 9:
        return DebTxStatus.install;
      case 6:
        return DebTxStatus.remove;
      case 10:
        return DebTxStatus.update;
      case 14:
        return DebTxStatus.verifying;
      default:
        return DebTxStatus.other;
    }
  }

  /// PackageKit exit indexes (`PackageKitExit`: unknown=0, success=1,
  /// failed=2, cancelled=3, killed=6, cancelledPriority=9).
  DebTxOutcome _mapExit(int exit) => switch (exit) {
    1 => DebTxOutcome.success,
    3 || 6 || 9 => DebTxOutcome.cancelled,
    _ => DebTxOutcome.failed,
  };

  /// PackageKit error names (`PackageKitError` enum order, 0.2.7), so
  /// the backend's error mapping keys off the same names the vendored
  /// client would have produced (`packageNotFound`, …).
  String _errorName(int code) =>
      code >= 0 && code < _errorNames.length ? _errorNames[code] : 'unknown';

  static const _errorNames = [
    'unknown',
    'outOfMemory',
    'noNetwork',
    'notSupported',
    'internalError',
    'gpgFailure',
    'packageIdInvalid',
    'packageNotInstalled',
    'packageNotFound',
    'packageAlreadyInstalled',
    'packageDownloadFailed',
    'groupNotFound',
    'groupListInvalid',
    'dependencyResolutionFailed',
    'filterInvalid',
    'createThreadFailed',
    'transactionError',
    'transactionCancelled',
    'noCache',
    'repositoryNotFound',
    'cannotRemoveSystemPackage',
    'processKill',
    'failedInitialization',
    'failedFinalize',
    'failedConfigParsing',
    'cannotCancel',
    'cannotGetLock',
    'noPackagesToUpdate',
    'cannotWriteRepositoryConfig',
    'localInstallFailed',
    'badGpgSignature',
    'missingGpgSignature',
    'cannotInstallSourcePackage',
    'repositoryConfigurationError',
    'noLicenseAgreement',
    'fileConflicts',
    'packageConflicts',
    'repositoryNotAvailable',
    'invalidPackageFile',
    'packageInstallBlocked',
    'packageCorrupt',
    'allPackagesAlreadyInstalled',
    'fileNotFound',
    'noMoreMirrorsToTry',
    'noDistroUpgradeData',
    'incompatibleArchitecture',
    'noSpaceOnDevice',
    'mediaChangeRequired',
    'notAuthorized',
    'updateNotFound',
    'cannotInstallRepositoryUnsigned',
    'cannotUpdateRepositoryUnsigned',
    'cannotGetFileList',
    'cannotGetRequires',
    'cannotDisableRepository',
    'restrictedDownload',
    'packageFailedToConfigure',
    'packageFailedToBuild',
    'packageFailedToInstall',
    'packageFailedToRemove',
    'updateFailedDueToRunningProcess',
    'packageDatabaseChanged',
    'provideTypeNotSupported',
    'installRootInvalid',
    'cannotFetchSources',
    'cancelledPriority',
    'unfinishedTransaction',
    'lockRequired',
    'repositoryAlreadySet',
  ];

  Future<DebTransaction> _mutate(
    String name,
    Future<void> Function(DBusRemoteObject tx, String id) action, {
    required bool preferInstalled,
  }) async {
    final bus = await _connectedBus();
    // Resolve fresh: origin/data fields can shift between query and
    // transaction — never trust a cached id (rpm research D4).
    final packageId = await _resolvePackageId(
      name,
      preferInstalled: preferInstalled,
    );
    final txPath = await _createTransaction(bus);
    final tx = DBusRemoteObject(bus, name: _busName, path: txPath);
    final controller = StreamController<DebTxEvent>();
    var errorCode = '';
    var errorDetails = '';
    final sub =
        DBusSignalStream(
          bus,
          sender: _busName,
          interface: _txInterface,
          path: txPath,
        ).listen((signal) {
          if (controller.isClosed) return;
          switch (signal.name) {
            case 'ItemProgress': // 'suu'
              if (signal.values.length == 3) {
                controller.add(
                  DebTxProgress(
                    status: _mapStatus(signal.values[1].asUint32()),
                    percentage: signal.values[2].asUint32().clamp(0, 100),
                  ),
                );
              }
            case 'ErrorCode': // 'us'
              if (signal.values.length == 2) {
                errorCode = _errorName(signal.values[0].asUint32());
                if (errorDetails.isEmpty) {
                  errorDetails = signal.values[1].asString();
                }
              }
            case 'Finished': // 'uu'
              final outcome = signal.values.isEmpty
                  ? DebTxOutcome.failed
                  : _mapExit(signal.values[0].asUint32());
              controller.add(
                DebTxDone(
                  outcome: outcome,
                  errorCode: errorCode,
                  errorDetails: errorDetails.isEmpty
                      ? 'exit: ${outcome.name}'
                      : errorDetails,
                ),
              );
              controller.close();
            case 'Destroy': // ''
              controller.add(
                const DebTxDone(
                  outcome: DebTxOutcome.failed,
                  errorDetails: 'transaction destroyed by daemon',
                ),
              );
              controller.close();
          }
        });
    // When the handle stops listening, release the daemon subscription.
    controller.onCancel = () => sub.cancel();
    try {
      await action(tx, packageId);
    } catch (e) {
      await sub.cancel();
      if (!controller.isClosed) await controller.close();
      throw _wrap(e);
    }
    return DebTransaction(
      events: controller.stream,
      cancel: () async {
        // Don't cancel the event subscription here: the Finished
        // event must still reach the handle to resolve honestly.
        try {
          await tx.callMethod(
            _txInterface,
            'Cancel',
            const [],
            replySignature: DBusSignature(''),
          );
        } catch (_) {}
      },
    );
  }

  @override
  Future<DebTransaction> install(String name) => _mutate(
    name,
    (tx, id) => tx.callMethod(_txInterface, 'InstallPackages', [
      DBusUint64(0),
      DBusArray.string([id]),
    ], replySignature: DBusSignature('')),
    preferInstalled: false,
  );

  @override
  Future<DebTransaction> remove(String name) => _mutate(
    name,
    (tx, id) => tx.callMethod(_txInterface, 'RemovePackages', [
      DBusUint64(0),
      DBusArray.string([id]),
      const DBusBoolean(false),
      const DBusBoolean(false),
    ], replySignature: DBusSignature('')),
    preferInstalled: true,
  );

  @override
  Future<DebTransaction> update(String name) => _mutate(
    name,
    (tx, id) => tx.callMethod(_txInterface, 'UpdatePackages', [
      DBusUint64(0),
      DBusArray.string([id]),
    ], replySignature: DBusSignature('')),
    preferInstalled: true,
  );
}
