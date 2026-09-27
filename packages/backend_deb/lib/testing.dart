/// Scripted [PackageKitTransport] for tests. Never touches D-Bus.
///
/// Import via `package:backend_deb/testing.dart` — kept out of the
/// main barrel so production code never depends on it.
library;

import 'dart:async';

import 'src/transport.dart';

/// Builds a [DebTransaction] that replays [script] on listen, paced so
/// the handle (and the exam's cancel test) can observe each phase.
/// [cancel] injects a terminal cancelled event.
DebTransaction scriptedTransaction(List<DebTxEvent> script) {
  late final StreamController<DebTxEvent> controller;
  controller = StreamController<DebTxEvent>(
    onListen: () async {
      for (final event in script) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (controller.isClosed) return;
        controller.add(event);
        if (event is DebTxDone) {
          await controller.close();
          return;
        }
      }
      // Script without a terminal event: the handle must not hang.
      if (!controller.isClosed) await controller.close();
    },
  );
  return DebTransaction(
    events: controller.stream,
    cancel: () async {
      if (!controller.isClosed) {
        controller.add(const DebTxDone(outcome: DebTxOutcome.cancelled));
        await controller.close();
      }
    },
  );
}

List<DebTxEvent> _installScript() => const [
  DebTxProgress(status: DebTxStatus.download, percentage: 10),
  DebTxProgress(status: DebTxStatus.download, percentage: 50),
  DebTxProgress(status: DebTxStatus.download, percentage: 90),
  DebTxProgress(status: DebTxStatus.verifying, percentage: 0),
  DebTxProgress(status: DebTxStatus.install, percentage: 0),
  DebTxDone(outcome: DebTxOutcome.success),
];

List<DebTxEvent> _quickScript(DebTxStatus status) => [
  DebTxProgress(status: status, percentage: 30),
  DebTxProgress(status: status, percentage: 80),
  const DebTxDone(outcome: DebTxOutcome.success),
];

class StubPackageKitTransport extends PackageKitTransport {
  /// Transactions the stub claims to have spent, mirroring the real
  /// transport's counts: [installedNames] = 1, [getDetails] = 2
  /// (SearchNames + GetDetails), [installedPackages] = 2 (GetPackages +
  /// GetDetails). Failed attempts count too.
  int transactionCount = 0;

  /// Scripted name list served by [installedNames] (the legacy path).
  List<String> installedNamesScript = const ['installed-deb'];

  /// Scripted per-name details served by [getDetails].
  final Map<String, DebPackageData> detailsScript = {
    'test-deb': const DebPackageData(
      name: 'test-deb',
      summary: 'a test deb',
      description: 'A longer description of the test deb.',
      version: '1.0',
      url: 'https://example.com/test-deb',
    ),
    'installed-deb': const DebPackageData(
      name: 'installed-deb',
      summary: 'an installed deb',
      description: 'Installed, unsandboxed.',
      version: '2.0',
      installedVersion: '2.0',
      url: 'https://example.com/installed-deb',
    ),
  };

  /// Scripted snapshot served by [installedPackages] (the bulk path).
  List<DebPackageData> installedPackagesScript = const [
    DebPackageData(
      name: 'installed-deb',
      summary: 'an installed deb',
      description: 'Installed, unsandboxed.',
      version: '2.0',
      installedVersion: '2.0',
      url: 'https://example.com/installed-deb',
    ),
  ];

  /// When set, [installedPackages] throws this instead of serving
  /// [installedPackagesScript], exercising the backend's legacy fallback.
  PackageKitTransportException? installedPackagesFailure;

  @override
  Future<void> checkAvailable() async {}

  @override
  Future<List<DebPackageData>> search(String query) async => const [
    DebPackageData(
      name: 'test-deb',
      summary: 'a test deb',
      description: 'A longer description of the test deb.',
      version: '1.0',
    ),
  ];

  @override
  Future<DebPackageData> getDetails(String name) async {
    transactionCount += 2;
    final p = detailsScript[name];
    if (p == null) {
      throw PackageKitNotFoundException('package "$name" not found');
    }
    return p;
  }

  @override
  Future<List<String>> installedNames() async {
    transactionCount += 1;
    return installedNamesScript;
  }

  @override
  Future<List<DebPackageData>> installedPackages() async {
    transactionCount += 2;
    final failure = installedPackagesFailure;
    if (failure != null) throw failure;
    return installedPackagesScript;
  }

  @override
  Future<List<DebPackageData>> updatesAvailable() async => const [
    DebPackageData(
      name: 'installed-deb',
      summary: '',
      description: '',
      version: '2.1',
      installedVersion: '2.0',
    ),
  ];

  @override
  Future<DebTransaction> install(String name) async {
    if (name == 'no.such.deb') {
      throw PackageKitNotFoundException('package "$name" not found');
    }
    return scriptedTransaction(_installScript());
  }

  @override
  Future<DebTransaction> remove(String name) async =>
      scriptedTransaction(_quickScript(DebTxStatus.remove));

  @override
  Future<DebTransaction> update(String name) async =>
      scriptedTransaction(_quickScript(DebTxStatus.update));
}
