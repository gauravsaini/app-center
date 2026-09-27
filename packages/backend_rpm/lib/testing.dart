/// Scripted [RpmTransport] for tests. Never touches D-Bus.
///
/// Import via `package:backend_rpm/testing.dart` — kept out of the
/// main barrel so production code never depends on it.
///
/// Fixtures (all 5-token IDs — the stub is the contract that the real
/// backend speaks the dnf5 wire shape, research §10):
/// - `installedIds` → firefox x86_64 + glibc i686 (the i686 entry proves
///   multi-arch cards stay separate).
/// - `searchScript['firefox']` → firefox x86_64 + i686 candidates.
/// - [installTargetId] (vim, available) → the install flow;
///   [installedTargetId] (firefox x86_64) → idempotent `Done(noop: true)`.
/// - [unknownTargetId] → typed not-found.
/// - Scripted transactions mirror the deb stub: paced progress scripts
///   so the handle and the exam's cancel test observe each phase;
///   cancel injects a terminal cancelled event.
library;

import 'dart:async';

import 'src/transport.dart';

/// Builds an [RpmTransaction] that replays [script] on listen, paced so
/// the handle (and the exam's cancel test) can observe each phase.
/// [cancel] injects a terminal cancelled event.
RpmTransaction scriptedTransaction(List<RpmTxEvent> script) {
  late final StreamController<RpmTxEvent> controller;
  controller = StreamController<RpmTxEvent>(
    onListen: () async {
      for (final event in script) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (controller.isClosed) return;
        controller.add(event);
        if (event is RpmTxDone) {
          await controller.close();
          return;
        }
      }
      // Script without a terminal event: the handle must not hang.
      if (!controller.isClosed) await controller.close();
    },
  );
  return RpmTransaction(
    events: controller.stream,
    cancel: () async {
      if (!controller.isClosed) {
        controller.add(const RpmTxDone(outcome: RpmTxOutcome.cancelled));
        await controller.close();
      }
    },
  );
}

List<RpmTxEvent> _installScript() => const [
  RpmTxProgress(status: RpmTxStatus.download, percentage: 10),
  RpmTxProgress(status: RpmTxStatus.download, percentage: 50),
  RpmTxProgress(status: RpmTxStatus.download, percentage: 90),
  RpmTxProgress(status: RpmTxStatus.verifying, percentage: 0),
  RpmTxProgress(status: RpmTxStatus.install, percentage: 0),
  RpmTxDone(outcome: RpmTxOutcome.success),
];

List<RpmTxEvent> _quickScript(RpmTxStatus status) => [
  RpmTxProgress(status: status, percentage: 30),
  RpmTxProgress(status: status, percentage: 80),
  const RpmTxDone(outcome: RpmTxOutcome.success),
];

class StubRpmTransport extends RpmTransport {
  /// vim — available, the exam's install target.
  static const installTargetId = 'vim;9.1-1.fc42;x86_64;fedora;';

  /// firefox x86_64 — installed, the exam's idempotent-install target.
  static const installedTargetId =
      'firefox;135.0-1.fc42;x86_64;updates;installed';

  /// glibc i686 — installed compat-arch package; proves multi-arch
  /// cards stay separate.
  static const glibcI686Id = 'glibc;2.39-2.fc42;i686;fedora;installed';

  /// Unknown package — every lookup throws the typed not-found.
  static const unknownTargetId = 'nope;1.0-1.fc42;x86_64;fedora;';

  /// When false, [checkAvailable] throws (daemon unreachable).
  bool available = true;

  /// Transactions the stub claims to have spent, mirroring the real
  /// transport's counts: [installedIds] = 1, [getDetails] = 2
  /// (SearchNames + GetDetails), [installedPackages] = 2 (GetPackages +
  /// GetDetails). Failed attempts count too.
  int transactionCount = 0;

  /// Mutate calls the stub served, in order (proves the remove-noop
  /// path never starts a transaction).
  final List<String> installCalls = [];
  final List<String> removeCalls = [];
  final List<String> updateCalls = [];

  /// Scripted id list served by [installedIds] (the legacy path).
  List<String> installedIdsScript = const [installedTargetId, glibcI686Id];

  /// Scripted per-id details served by [getDetails].
  final Map<String, RpmPackageData> detailsScript = {
    installTargetId: const RpmPackageData(
      id: installTargetId,
      name: 'vim',
      arch: 'x86_64',
      evr: '9.1-1.fc42',
      summary: 'The VIM editor',
      description: 'Vim is an advanced text editor.',
      license: 'Vim',
      homepage: 'https://www.vim.org/',
      installSize: 12345678,
    ),
    installedTargetId: const RpmPackageData(
      id: installedTargetId,
      name: 'firefox',
      arch: 'x86_64',
      evr: '135.0-1.fc42',
      summary: 'Web browser',
      description: 'Mozilla Firefox web browser.',
      license: 'MPL-2.0',
      homepage: 'https://www.mozilla.org/firefox/',
      installSize: 250000000,
      installed: true,
    ),
    glibcI686Id: const RpmPackageData(
      id: glibcI686Id,
      name: 'glibc',
      arch: 'i686',
      evr: '2.39-2.fc42',
      summary: 'GNU C library (32-bit)',
      description: '32-bit compatibility C library.',
      license: 'LGPL-2.1-or-later',
      installSize: 18000000,
      installed: true,
    ),
  };

  /// Scripted snapshot served by [installedPackages] (the bulk path).
  List<RpmPackageData> installedPackagesScript = const [
    RpmPackageData(
      id: installedTargetId,
      name: 'firefox',
      arch: 'x86_64',
      evr: '135.0-1.fc42',
      summary: 'Web browser',
      description: 'Mozilla Firefox web browser.',
      license: 'MPL-2.0',
      homepage: 'https://www.mozilla.org/firefox/',
      installSize: 250000000,
      installed: true,
    ),
    RpmPackageData(
      id: glibcI686Id,
      name: 'glibc',
      arch: 'i686',
      evr: '2.39-2.fc42',
      summary: 'GNU C library (32-bit)',
      description: '32-bit compatibility C library.',
      license: 'LGPL-2.1-or-later',
      installSize: 18000000,
      installed: true,
    ),
  ];

  /// When set, [installedPackages] throws this instead of serving
  /// [installedPackagesScript], exercising the backend's legacy fallback.
  RpmTransportException? installedPackagesFailure;

  /// Scripted search results per query.
  final Map<String, List<RpmPackageData>> searchScript = {
    'firefox': const [
      RpmPackageData(
        id: 'firefox;136.0-1.fc42;x86_64;updates;',
        name: 'firefox',
        arch: 'x86_64',
        evr: '136.0-1.fc42',
        summary: 'Web browser',
      ),
      RpmPackageData(
        id: 'firefox;136.0-1.fc42;i686;updates;',
        name: 'firefox',
        arch: 'i686',
        evr: '136.0-1.fc42',
        summary: 'Web browser (32-bit)',
      ),
    ],
  };

  /// Scripted update entries served by [updatesAvailable].
  List<RpmPackageData> updatesScript = const [
    RpmPackageData(
      id: 'firefox;136.0-1.fc42;x86_64;updates;',
      name: 'firefox',
      arch: 'x86_64',
      evr: '136.0-1.fc42',
      summary: 'Web browser',
      installedEvr: '135.0-1.fc42',
    ),
  ];

  /// Ids whose update is a daemon-side no-op: the transaction succeeds
  /// with zero progress events → `Done(noop: true)`.
  final Set<String> emptyUpdateIds = {};

  /// Card keys the stub treats as installed for mutate-time checks.
  Set<String> get _installedCards => {
    for (final id in installedIdsScript) RpmPackageId.parse(id).cardKey,
  };

  @override
  Future<void> checkAvailable() async {
    if (!available) {
      throw RpmTransportException('packagekit unreachable: stub daemon down');
    }
  }

  @override
  Future<List<RpmPackageData>> search(String query) async =>
      searchScript[query] ?? const [];

  @override
  Future<RpmPackageData> getDetails(String packageId) async {
    transactionCount += 2;
    final p = detailsScript[packageId];
    if (p == null) {
      throw RpmNotFoundException('package "$packageId" not found');
    }
    return p;
  }

  @override
  Future<List<String>> installedIds() async {
    transactionCount += 1;
    return installedIdsScript;
  }

  @override
  Future<List<RpmPackageData>> installedPackages() async {
    transactionCount += 2;
    final failure = installedPackagesFailure;
    if (failure != null) throw failure;
    return installedPackagesScript;
  }

  @override
  Future<List<RpmPackageData>> updatesAvailable() async => updatesScript;

  @override
  Future<RpmTransaction> install(String packageId) async {
    installCalls.add(packageId);
    if (packageId == unknownTargetId || !detailsScript.containsKey(packageId)) {
      throw RpmNotFoundException('package "$packageId" not found');
    }
    return scriptedTransaction(_installScript());
  }

  @override
  Future<RpmTransaction> remove(String packageId) async {
    removeCalls.add(packageId);
    if (!_installedCards.contains(RpmPackageId.parse(packageId).cardKey)) {
      throw RpmNotFoundException('package "$packageId" is not installed');
    }
    return scriptedTransaction(_quickScript(RpmTxStatus.remove));
  }

  @override
  Future<RpmTransaction> update(String packageId) async {
    updateCalls.add(packageId);
    if (packageId == unknownTargetId || !detailsScript.containsKey(packageId)) {
      throw RpmNotFoundException('package "$packageId" not found');
    }
    if (emptyUpdateIds.contains(packageId)) {
      // Daemon-side no-op: success with zero progress events.
      return scriptedTransaction(const [
        RpmTxDone(outcome: RpmTxOutcome.success),
      ]);
    }
    return scriptedTransaction(_quickScript(RpmTxStatus.update));
  }
}
