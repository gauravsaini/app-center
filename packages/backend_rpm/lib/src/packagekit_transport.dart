/// [RealRpmPackageKitTransport]: the real transport, over raw D-Bus
/// (`package:dbus`).
///
/// Why raw D-Bus instead of `package:packagekit`: the vendored 0.2.7
/// client parses every package-bearing signal through its strict 4-token
/// `PackageKitPackageId.fromString` *inside* the signal-stream `.map()` —
/// a dnf5 5-token ID throws there and the event never materializes
/// (research D1). This transport therefore speaks the same
/// `org.freedesktop.PackageKit.Transaction` wire protocol the client
/// uses (method/signal signatures read from `packagekit` 0.2.7's
/// source), but decodes signals itself and parses IDs with
/// [RpmPackageId.parse] at the seam. Method calls take verbatim ID
/// strings — the daemon accepts full 5-token IDs.
///
/// Nothing here is live-verified (no Fedora box in the sandbox); every
/// wire claim cites its source in comments.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';

import 'transport.dart';

/// One decoded `Package` signal: `(info, package-id, summary)`.
///
/// The id is the daemon's verbatim string — unparsed. Parsing happens
/// in the mapping step so one corrupt id can be skipped without failing
/// the whole enumeration.
class RpmRawPackage {
  const RpmRawPackage({
    required this.installed,
    required this.id,
    required this.summary,
  });

  final bool installed;
  final String id;
  final String summary;
}

/// One decoded `Details` signal dict (`a{sv}`).
class RpmRawDetails {
  const RpmRawDetails({
    required this.id,
    this.summary = '',
    this.description = '',
    this.license = '',
    this.url = '',
    this.size = 0,
  });

  final String id;
  final String summary;
  final String description;
  final String license;
  final String url;
  final int size;
}

class RealRpmPackageKitTransport extends RpmTransport {
  /// Filter mask for catalog search: `PackageKitFilter.arch`
  /// (native arch + noarch; drops compat arches — research D3).
  ///
  /// Bit index from `packagekit` 0.2.7's `PackageKitFilter` enum order:
  /// unknown=0, none=1, installed=2, …, arch=18.
  static const int searchFilterMask = 1 << 18;

  /// Filter mask for the installed enumeration: `PackageKitFilter.installed`
  /// ONLY — deliberately no arch bit, so installed compat-arch (i686)
  /// packages still list (research D3/D4).
  static const int installedFilterMask = 1 << 2;

  RealRpmPackageKitTransport();

  DBusClient? _bus;
  bool _connected = false;

  RpmTransportException _wrap(Object e) =>
      RpmTransportException('packagekit: $e');

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
    // transactions on its own — same as the deb transport.
    await _createTransaction(bus).timeout(const Duration(seconds: 2));
  }

  /// Runs [action] on a throwaway transaction, collecting `Package`
  /// signals until the transaction finishes. Throws
  /// [RpmTransportException] (never raw D-Bus errors) on failure.
  Future<List<RpmRawPackage>> _packageEvents(
    Future<void> Function(DBusRemoteObject tx) action,
  ) async {
    final bus = await _connectedBus();
    final txPath = await _createTransaction(bus);
    final tx = DBusRemoteObject(bus, name: _busName, path: txPath);
    final packages = <RpmRawPackage>[];
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
                  RpmRawPackage(
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
      throw RpmTransportException('packagekit query timed out');
    } catch (e) {
      throw _wrap(e);
    } finally {
      await sub.cancel();
    }
    return packages;
  }

  /// One batched `GetDetails` transaction; returns the raw `Details`
  /// dicts in arrival order.
  Future<List<RpmRawDetails>> _detailsEvents(List<String> ids) async {
    final bus = await _connectedBus();
    final txPath = await _createTransaction(bus);
    final tx = DBusRemoteObject(bus, name: _busName, path: txPath);
    final details = <RpmRawDetails>[];
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
                RpmRawDetails(
                  id: dict['package-id']?.asString() ?? '',
                  summary: dict['summary']?.asString() ?? '',
                  description: dict['description']?.asString() ?? '',
                  license: dict['license']?.asString() ?? '',
                  url: dict['url']?.asString() ?? '',
                  // `download-size` is wire-present but unsurfed in MVP
                  // (HLD §7); `size` is the install size.
                  size: dict['size']?.asUint64() ?? 0,
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
      throw RpmTransportException('packagekit details timed out');
    } catch (e) {
      throw _wrap(e);
    } finally {
      await sub.cancel();
    }
    return details;
  }

  /// Tolerant mapping of one raw package event; null when the daemon
  /// emitted an unparsable id (skipped, never fatal — LLD §3).
  RpmPackageData? _toData(RpmRawPackage e) {
    late final RpmPackageId id;
    try {
      id = RpmPackageId.parse(e.id);
    } on FormatException {
      return null;
    }
    return RpmPackageData(
      id: e.id,
      name: id.name,
      arch: id.arch,
      evr: id.evr,
      summary: e.summary,
      installed: e.installed,
    );
  }

  /// Pure merge step of [installedPackages], kept static so tests can
  /// exercise the (name, arch) dedupe without a D-Bus daemon.
  ///
  /// Per (name, arch) group: prefer the installed event's EVR; summary
  /// prefers the Details summary, falls back to the Package-event
  /// summary. Unparsable ids are skipped, never fatal.
  static List<RpmPackageData> mergeInstalledPackages(
    List<RpmRawPackage> packages,
    List<RpmRawDetails> details,
  ) {
    final byCard = <String, List<RpmRawPackage>>{};
    for (final p in packages) {
      late final RpmPackageId id;
      try {
        id = RpmPackageId.parse(p.id);
      } on FormatException {
        continue;
      }
      (byCard[id.cardKey] ??= []).add(p);
    }
    final detailsByCard = <String, RpmRawDetails>{};
    for (final d in details) {
      try {
        detailsByCard.putIfAbsent(RpmPackageId.parse(d.id).cardKey, () => d);
      } on FormatException {
        continue;
      }
    }
    return [
      for (final group in byCard.values)
        _mergeInstalledGroup(group, detailsByCard),
    ];
  }

  static RpmPackageData _mergeInstalledGroup(
    List<RpmRawPackage> group,
    Map<String, RpmRawDetails> detailsByCard,
  ) {
    // One card per (name, arch): prefer the installed entry, else the
    // first candidate.
    final chosen = group.firstWhere(
      (e) => e.installed,
      orElse: () => group.first,
    );
    // The group is non-empty and every member parsed (they were parsed
    // to build the group), so this cannot throw.
    final id = RpmPackageId.parse(chosen.id);
    final d = detailsByCard[id.cardKey];
    final detailSummary = d?.summary ?? '';
    return RpmPackageData(
      id: chosen.id,
      name: id.name,
      arch: id.arch,
      evr: id.evr,
      summary: detailSummary.isEmpty ? chosen.summary : detailSummary,
      description: d?.description ?? '',
      license: d?.license ?? '',
      homepage: d?.url ?? '',
      installSize: d?.size ?? 0,
      installed: chosen.installed,
    );
  }

  @override
  Future<List<RpmPackageData>> search(String query) async {
    late final List<RpmRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'SearchNames', [
          DBusUint64(searchFilterMask),
          DBusArray.string([query]),
        ], replySignature: DBusSignature('')),
      );
    } on RpmTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    // One card per (name, arch): the daemon already dedupes by NEVRA
    // (research §2); keep first-seen per card.
    final seen = <String>{};
    final out = <RpmPackageData>[];
    for (final e in events) {
      final data = _toData(e);
      if (data == null) continue;
      final key = '${data.name}.${data.arch}';
      if (seen.add(key)) out.add(data);
    }
    return out;
  }

  /// Re-resolve (name, arch) against a fresh SearchNames. The search
  /// runs WITHOUT the arch filter: installed compat-arch (i686)
  /// packages must still resolve (research D3). Origin/repo fields can
  /// shift between query and transaction, so mutate paths always
  /// resolve fresh rather than trusting a cached id (research D4).
  Future<String> _resolvePackageId(
    String name,
    String arch, {
    required bool preferInstalled,
  }) async {
    late final List<RpmRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'SearchNames', [
          DBusUint64(0),
          DBusArray.string([name]),
        ], replySignature: DBusSignature('')),
      );
    } on RpmTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final exact = <RpmRawPackage>[];
    for (final e in events) {
      late final RpmPackageId id;
      try {
        id = RpmPackageId.parse(e.id);
      } on FormatException {
        continue;
      }
      if (id.name == name && id.arch == arch) exact.add(e);
    }
    if (exact.isEmpty) {
      throw RpmNotFoundException('package "$name.$arch" not found');
    }
    int rank(RpmRawPackage e) => e.installed ? 0 : 1;
    exact.sort(
      (a, b) => preferInstalled
          ? rank(a).compareTo(rank(b))
          : rank(b).compareTo(rank(a)),
    );
    return exact.first.id;
  }

  RpmPackageId _parseOrNotFound(String packageId) {
    try {
      return RpmPackageId.parse(packageId);
    } on FormatException {
      throw RpmNotFoundException('unparseable package id: $packageId');
    }
  }

  @override
  Future<RpmPackageData> getDetails(String packageId) async {
    final parsed = _parseOrNotFound(packageId);
    final resolved = await _resolvePackageId(
      parsed.name,
      parsed.arch,
      preferInstalled: true,
    );
    late final List<RpmRawDetails> details;
    try {
      details = await _detailsEvents([resolved]);
    } on RpmTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    if (details.isEmpty) {
      throw RpmNotFoundException(
        'package "${parsed.name}.${parsed.arch}" not found',
      );
    }
    final d = details.first;
    final resolvedId = RpmPackageId.parse(resolved);
    return RpmPackageData(
      id: resolved,
      name: resolvedId.name,
      arch: resolvedId.arch,
      evr: resolvedId.evr,
      summary: d.summary,
      description: d.description,
      license: d.license,
      homepage: d.url,
      installSize: d.size,
      installed: resolvedId.isInstalled,
    );
  }

  @override
  Future<List<String>> installedIds() async {
    late final List<RpmRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'GetPackages', [
          DBusUint64(installedFilterMask),
        ], replySignature: DBusSignature('')),
      );
    } on RpmTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final ids = <String>[];
    for (final e in events) {
      try {
        RpmPackageId.parse(e.id);
      } on FormatException {
        continue; // skip garbage; never fail the whole list (LLD §3)
      }
      ids.add(e.id);
    }
    return ids;
  }

  @override
  Future<List<RpmPackageData>> installedPackages() async {
    late final List<RpmRawPackage> events;
    try {
      events = await _packageEvents(
        (tx) => tx.callMethod(_txInterface, 'GetPackages', [
          DBusUint64(installedFilterMask),
        ], replySignature: DBusSignature('')),
      );
    } on RpmTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    if (events.isEmpty) return const [];
    // Second (and last) transaction: one batched GetDetails for every
    // installed id. A batch failure throws RpmTransportException, which
    // propagates so the backend can fall back to the legacy path.
    final ids = <String>[];
    for (final e in events) {
      try {
        RpmPackageId.parse(e.id);
      } on FormatException {
        continue;
      }
      ids.add(e.id);
    }
    final details = await _detailsEvents(ids);
    return mergeInstalledPackages(events, details);
  }

  @override
  Future<List<RpmPackageData>> updatesAvailable() async {
    late final List<RpmRawPackage> updates;
    late final List<RpmRawPackage> installed;
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
    } on RpmTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final installedEvrByCard = <String, String>{};
    for (final p in installed) {
      try {
        final id = RpmPackageId.parse(p.id);
        installedEvrByCard.putIfAbsent(id.cardKey, () => id.evr);
      } on FormatException {
        continue;
      }
    }
    final out = <RpmPackageData>[];
    for (final u in updates) {
      late final RpmPackageId id;
      try {
        id = RpmPackageId.parse(u.id);
      } on FormatException {
        continue;
      }
      out.add(
        RpmPackageData(
          id: u.id,
          name: id.name,
          arch: id.arch,
          evr: id.evr,
          summary: u.summary,
          installedEvr: installedEvrByCard[id.cardKey],
        ),
      );
    }
    return out;
  }

  /// PackageKit status indexes (packagekit 0.2.7 `PackageKitStatus`
  /// enum order): remove=6, download=8, install=9, update=10,
  /// signatureCheck=14, downloadRepository=20 … downloadUpdateInfo=25,
  /// waitingForAuth=31.
  RpmTxStatus _mapStatus(int status) {
    switch (status) {
      case 8:
      case 20:
      case 21:
      case 22:
      case 23:
      case 24:
      case 25:
        return RpmTxStatus.download;
      case 9:
        return RpmTxStatus.install;
      case 6:
        return RpmTxStatus.remove;
      case 10:
        return RpmTxStatus.update;
      case 14:
        return RpmTxStatus.verifying;
      case 31:
        return RpmTxStatus.waitingForAuth;
      default:
        return RpmTxStatus.other;
    }
  }

  /// PackageKit exit indexes (`PackageKitExit`: unknown=0, success=1,
  /// failed=2, cancelled=3, killed=6, cancelledPriority=9).
  RpmTxOutcome _mapExit(int exit) => switch (exit) {
    1 => RpmTxOutcome.success,
    3 || 6 || 9 => RpmTxOutcome.cancelled,
    _ => RpmTxOutcome.failed,
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

  Future<RpmTransaction> _mutate(
    String packageId,
    Future<void> Function(DBusRemoteObject tx, String resolvedId) action, {
    required bool preferInstalled,
  }) async {
    final parsed = _parseOrNotFound(packageId);
    final bus = await _connectedBus();
    final resolvedId = await _resolvePackageId(
      parsed.name,
      parsed.arch,
      preferInstalled: preferInstalled,
    );
    final txPath = await _createTransaction(bus);
    final tx = DBusRemoteObject(bus, name: _busName, path: txPath);
    final controller = StreamController<RpmTxEvent>();
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
                  RpmTxProgress(
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
                  ? RpmTxOutcome.failed
                  : _mapExit(signal.values[0].asUint32());
              controller.add(
                RpmTxDone(
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
                const RpmTxDone(
                  outcome: RpmTxOutcome.failed,
                  errorDetails: 'transaction destroyed by daemon',
                ),
              );
              controller.close();
          }
        });
    // When the handle stops listening, release the daemon subscription.
    controller.onCancel = () => sub.cancel();
    try {
      await action(tx, resolvedId);
    } catch (e) {
      await sub.cancel();
      if (!controller.isClosed) await controller.close();
      throw _wrap(e);
    }
    return RpmTransaction(
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
  Future<RpmTransaction> install(String packageId) => _mutate(
    packageId,
    (tx, id) => tx.callMethod(_txInterface, 'InstallPackages', [
      DBusUint64(0),
      DBusArray.string([id]),
    ], replySignature: DBusSignature('')),
    preferInstalled: false,
  );

  @override
  Future<RpmTransaction> remove(String packageId) => _mutate(
    packageId,
    (tx, id) => tx.callMethod(_txInterface, 'RemovePackages', [
      DBusUint64(0),
      DBusArray.string([id]),
      const DBusBoolean(false),
      const DBusBoolean(false),
    ], replySignature: DBusSignature('')),
    preferInstalled: true,
  );

  @override
  Future<RpmTransaction> update(String packageId) => _mutate(
    packageId,
    (tx, id) => tx.callMethod(_txInterface, 'UpdatePackages', [
      DBusUint64(0),
      DBusArray.string([id]),
    ], replySignature: DBusSignature('')),
    preferInstalled: true,
  );
}
