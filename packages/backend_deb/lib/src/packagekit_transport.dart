/// [RealPackageKitTransport]: the real transport, over `package:packagekit`.
library;

import 'dart:async';

import 'package:packagekit/packagekit.dart';

import 'transport.dart';

class RealPackageKitTransport extends PackageKitTransport {
  /// Construction never touches D-Bus; the client connects lazily on
  /// first use, so building this on a PackageKit-less box is safe.
  RealPackageKitTransport({PackageKitClient? client}) : _client = client;

  PackageKitClient? _client;
  bool _connected = false;

  PackageKitTransportException _wrap(Object e) =>
      PackageKitTransportException(e.toString());

  Future<PackageKitClient> _connectedClient() async {
    if (_connected) return _client!;
    try {
      final client = _client ?? PackageKitClient();
      await client.connect().timeout(const Duration(seconds: 2));
      _client = client;
      _connected = true;
      return client;
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<void> checkAvailable() async {
    final client = await _connectedClient();
    try {
      // Probe: creating a transaction proves the daemon answers.
      // The probe is never given an action; the daemon reaps idle
      // transactions on its own.
      await client.createTransaction().timeout(const Duration(seconds: 2));
    } catch (e) {
      throw _wrap(e);
    }
  }

  /// Runs [action] on a throwaway transaction, collecting package events
  /// until the transaction finishes. Throws [PackageKitTransportException]
  /// (never raw D-Bus errors) on failure.
  Future<List<PackageKitPackageEvent>> _packageEvents(
    Future<void> Function(PackageKitTransaction tx) action,
  ) async {
    final client = await _connectedClient();
    late final PackageKitTransaction tx;
    try {
      tx = await client.createTransaction();
    } catch (e) {
      throw _wrap(e);
    }
    final packages = <PackageKitPackageEvent>[];
    String? error;
    final done = Completer<void>();
    final sub = tx.events.listen((event) {
      if (event is PackageKitPackageEvent) {
        packages.add(event);
      } else if (event is PackageKitErrorCodeEvent) {
        error ??= '${event.code.name}: ${event.details}';
      } else if (event is PackageKitFinishedEvent ||
          event is PackageKitDestroyEvent) {
        if (!done.isCompleted) done.complete();
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

  Future<List<PackageKitDetailsEvent>> _detailsEvents(
    List<PackageKitPackageId> ids,
  ) async {
    final client = await _connectedClient();
    late final PackageKitTransaction tx;
    try {
      tx = await client.createTransaction();
    } catch (e) {
      throw _wrap(e);
    }
    final details = <PackageKitDetailsEvent>[];
    final done = Completer<void>();
    final sub = tx.events.listen((event) {
      if (event is PackageKitDetailsEvent) {
        details.add(event);
      } else if (event is PackageKitFinishedEvent ||
          event is PackageKitDestroyEvent) {
        if (!done.isCompleted) done.complete();
      }
    });
    try {
      await tx.getDetails(ids);
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

  DebPackageData _mergeGroup(List<PackageKitPackageEvent> group) {
    // One card per package name: prefer the installed entry, else the
    // first candidate. No cross-version merging beyond that.
    final e = group.firstWhere(
      (e) => e.info == PackageKitInfo.installed,
      orElse: () => group.first,
    );
    return DebPackageData(
      name: e.packageId.name,
      summary: e.summary,
      description: '',
      version: e.packageId.version,
      installedVersion: e.info == PackageKitInfo.installed
          ? e.packageId.version
          : null,
    );
  }

  @override
  Future<List<DebPackageData>> search(String query) async {
    late final List<PackageKitPackageEvent> events;
    try {
      events = await _packageEvents((tx) => tx.searchNames([query]));
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final byName = <String, List<PackageKitPackageEvent>>{};
    for (final e in events) {
      (byName[e.packageId.name] ??= []).add(e);
    }
    return [for (final group in byName.values) _mergeGroup(group)];
  }

  Future<PackageKitPackageId> _resolvePackageId(
    String name, {
    required bool preferInstalled,
  }) async {
    late final List<PackageKitPackageEvent> events;
    try {
      events = await _packageEvents((tx) => tx.searchNames([name]));
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final exact = events.where((e) => e.packageId.name == name).toList();
    if (exact.isEmpty) {
      throw PackageKitNotFoundException('package "$name" not found');
    }
    int rank(PackageKitPackageEvent e) =>
        e.info == PackageKitInfo.installed ? 0 : 1;
    exact.sort(
      (a, b) => preferInstalled
          ? rank(a).compareTo(rank(b))
          : rank(b).compareTo(rank(a)),
    );
    return exact.first.packageId;
  }

  @override
  Future<DebPackageData> getDetails(String name) async {
    final id = await _resolvePackageId(name, preferInstalled: true);
    late final List<PackageKitDetailsEvent> details;
    try {
      details = await _detailsEvents([id]);
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final d = details.isEmpty ? null : details.first;
    return DebPackageData(
      name: id.name,
      summary: d?.summary ?? '',
      description: d?.description ?? '',
      version: id.version,
      installedVersion: null,
    );
  }

  @override
  Future<List<String>> installedNames() async {
    late final List<PackageKitPackageEvent> events;
    try {
      events = await _packageEvents(
        (tx) => tx.getPackages(filter: {PackageKitFilter.installed}),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    return [for (final e in events) e.packageId.name];
  }

  @override
  Future<List<DebPackageData>> updatesAvailable() async {
    late final List<PackageKitPackageEvent> updates;
    late final List<PackageKitPackageEvent> installed;
    try {
      updates = await _packageEvents((tx) => tx.getUpdates());
      installed = await _packageEvents(
        (tx) => tx.getPackages(filter: {PackageKitFilter.installed}),
      );
    } on PackageKitTransportException {
      rethrow;
    } catch (e) {
      throw _wrap(e);
    }
    final installedByName = {
      for (final p in installed) p.packageId.name: p.packageId.version,
    };
    return [
      for (final u in updates)
        DebPackageData(
          name: u.packageId.name,
          summary: u.summary,
          description: '',
          version: u.packageId.version,
          installedVersion: installedByName[u.packageId.name],
        ),
    ];
  }

  DebTxStatus _mapStatus(PackageKitStatus status) {
    switch (status) {
      case PackageKitStatus.download:
      case PackageKitStatus.downloadRepository:
      case PackageKitStatus.downloadPackageList:
      case PackageKitStatus.downloadFileList:
      case PackageKitStatus.downloadChangelog:
      case PackageKitStatus.downloadGroup:
      case PackageKitStatus.downloadUpdateInfo:
        return DebTxStatus.download;
      case PackageKitStatus.install:
        return DebTxStatus.install;
      case PackageKitStatus.remove:
        return DebTxStatus.remove;
      case PackageKitStatus.update:
        return DebTxStatus.update;
      case PackageKitStatus.signatureCheck:
        return DebTxStatus.verifying;
      default:
        return DebTxStatus.other;
    }
  }

  Future<DebTransaction> _mutate(
    String name,
    Future<void> Function(PackageKitTransaction tx, PackageKitPackageId id)
    action, {
    required bool preferInstalled,
  }) async {
    final client = await _connectedClient();
    final packageId = await _resolvePackageId(
      name,
      preferInstalled: preferInstalled,
    );
    late final PackageKitTransaction tx;
    try {
      tx = await client.createTransaction();
    } catch (e) {
      throw _wrap(e);
    }
    final controller = StreamController<DebTxEvent>();
    var errorCode = '';
    var errorDetails = '';
    final sub = tx.events.listen((event) {
      if (controller.isClosed) return;
      if (event is PackageKitItemProgressEvent) {
        controller.add(
          DebTxProgress(
            status: _mapStatus(event.status),
            percentage: event.percentage.clamp(0, 100),
          ),
        );
      } else if (event is PackageKitErrorCodeEvent) {
        errorCode = event.code.name;
        if (errorDetails.isEmpty) errorDetails = event.details;
      } else if (event is PackageKitFinishedEvent) {
        final outcome = switch (event.exit) {
          PackageKitExit.success => DebTxOutcome.success,
          PackageKitExit.cancelled ||
          PackageKitExit.cancelledPriority ||
          PackageKitExit.killed => DebTxOutcome.cancelled,
          _ => DebTxOutcome.failed,
        };
        controller.add(
          DebTxDone(
            outcome: outcome,
            errorCode: errorCode,
            errorDetails: errorDetails.isEmpty
                ? 'exit: ${event.exit.name}'
                : errorDetails,
          ),
        );
        controller.close();
      } else if (event is PackageKitDestroyEvent) {
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
          await tx.cancel();
        } catch (_) {}
      },
    );
  }

  @override
  Future<DebTransaction> install(String name) => _mutate(
    name,
    (tx, id) => tx.installPackages([id]),
    preferInstalled: false,
  );

  @override
  Future<DebTransaction> remove(String name) =>
      _mutate(name, (tx, id) => tx.removePackages([id]), preferInstalled: true);

  @override
  Future<DebTransaction> update(String name) =>
      _mutate(name, (tx, id) => tx.updatePackages([id]), preferInstalled: true);
}
