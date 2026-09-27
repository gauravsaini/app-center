/// Scripted [PacmanTransport] for tests. Never touches the live system.
///
/// Import via `package:backend_pacman/testing.dart` — kept out of the
/// main barrel so production code never depends on it.
///
/// Fixtures (all verbatim from docs/architecture/pacman-research.md §2 —
/// reconstructed shapes, not live captures; the stub is the contract
/// that the real pacman speaks those shapes):
/// - `installedScript` → the §2.1 block incl. the epoch-prefixed
///   `docker 1:28.5.1-1` line (version opacity proof).
/// - `searchScript['firefox']` → the §2.2 block incl. the
///   wrapped-description `firefox-i18n-de` entry and the `[installed]`
///   flag.
/// - `detailsScript` → the §2.3 `-Si nginx` block and a `-Qi` block
///   without `Repository`/`Download Size` (fallback proof).
/// - [installTargetId] (vim, available) → the §2.7 install flow;
///   [installedTargetId] (firefox) → idempotent `Done(noop: true)`.
/// - [unknownTargetId] → typed not-found.
/// - Scripted transactions replay the §2.7 transaction lines as
///   parsed events, paced so the handle and the exam's cancel test
///   observe each phase; cancel injects a terminal cancelled event.
library;

import 'dart:async';

import 'src/cli_transport.dart';
import 'src/metadata.dart';
import 'src/transport.dart';

/// Builds a [PacmanTransaction] that replays [script] on listen, paced
/// so the handle (and the exam's cancel test) can observe each phase.
/// [cancel] injects a terminal cancelled event.
PacmanTransaction scriptedTransaction(List<PacmanTxEvent> script) {
  late final StreamController<PacmanTxEvent> controller;
  controller = StreamController<PacmanTxEvent>(
    onListen: () async {
      for (final event in script) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (controller.isClosed) return;
        controller.add(event);
        if (event is PacmanTxDone) {
          await controller.close();
          return;
        }
      }
      // Script without a terminal event: the handle must not hang.
      if (!controller.isClosed) await controller.close();
    },
  );
  return PacmanTransaction(
    events: controller.stream,
    cancel: () async {
      if (!controller.isClosed) {
        controller.add(
          const PacmanTxDone(
            exitCode: -15,
            stderr: 'killed by test cancel',
            cancelledByUs: true,
          ),
        );
        await controller.close();
      }
    },
  );
}

/// The §2.7 install transaction as parsed events: preparing (summary
/// latches the download size) → downloading → verifying → applying
/// with a real (1/2) → (2/2) fraction → done.
List<PacmanTxEvent> _installScript() => [
  const PacmanTxProgress(phase: PacmanTxPhase.preparing),
  PacmanTxProgress(
    phase: PacmanTxPhase.preparing,
    bytesTotal: parseSize('1.71 MiB'),
  ),
  PacmanTxProgress(
    phase: PacmanTxPhase.downloading,
    bytesTotal: parseSize('1.71 MiB'),
  ),
  const PacmanTxProgress(phase: PacmanTxPhase.verifying),
  const PacmanTxProgress(phase: PacmanTxPhase.applying, fraction: 0.5),
  const PacmanTxProgress(phase: PacmanTxPhase.applying, fraction: 1.0),
  const PacmanTxDone(exitCode: 0, stderr: ''),
];

class StubPacmanTransport extends PacmanTransport {
  /// vim — available, the exam's install target.
  static const installTargetId = 'vim;9.1-1;x86_64;extra';

  /// firefox — installed (the `-Q` path: empty arch/repo), the exam's
  /// idempotent-install target.
  static const installedTargetId = 'firefox;146.0-1;;';

  /// Unknown package — every lookup throws the typed not-found.
  static const unknownTargetId = 'nope;1.0-1;;';

  /// When false, [checkAvailable] throws (pacman binary missing).
  bool available = true;

  /// Scripted answer for [hasCheckupdates] (the pacman-contrib probe).
  bool checkupdatesPresent = true;

  /// Names the stub treats as installed for the noop checks.
  Set<String> installedNames = {'firefox'};

  /// Scripted snapshot served by [installedPackages] (the bulk path).
  /// Served through the REAL parser — the stub is the contract that
  /// the parser speaks the wire shape.
  List<PacmanPackageData> installedPackagesScript = parseQOutput(_qFixture);

  /// How many times the bulk path ran: proves listInstalled() is one
  /// CLI call, never N+1.
  int installedPackagesCalls = 0;

  /// Mutate calls the stub served, in order (proves the no-op paths
  /// never start a transaction).
  final List<String> installCalls = [];
  final List<String> removeCalls = [];
  final List<String> updateCalls = [];

  /// Scripted search results per query (the §2.2 fixture, parsed by
  /// the REAL parser).
  final Map<String, List<PacmanPackageData>> searchScript = {
    'firefox': parseSearchOutput(_ssFixture),
  };

  /// Scripted per-id details served by [getDetails].
  final Map<String, PacmanPackageData> detailsScript = {
    'vim;9.1-1;x86_64;extra': parseInfoOutput(
      _siVimFixture,
      'vim',
      installed: false,
    )!,
    installedTargetId: parseInfoOutput(
      _qiFirefoxFixture,
      'firefox',
      installed: true,
    )!,
  };

  /// Scripted update entries served by [updatesAvailable]: the §2.5
  /// block (old → new), parsed by the REAL parser.
  List<PacmanPackageData> updatesScript = parseUpdateLines(_quFixture);

  @override
  Future<void> checkAvailable() async {
    if (!available) {
      throw PacmanTransportException(
        ['pacman', '--version'],
        127,
        'pacman not found: stub binary missing',
      );
    }
  }

  @override
  Future<bool> hasCheckupdates() async => checkupdatesPresent;

  @override
  Future<List<PacmanPackageData>> search(String query) async =>
      searchScript[query] ?? const [];

  @override
  Future<PacmanPackageData> getDetails(String packageId) async {
    final p = detailsScript[packageId];
    if (p == null) {
      throw PacmanNotFoundException(
        ['pacman', '-Si/-Qi', '--', packageId],
        1,
        "error: package '$packageId' was not found.",
      );
    }
    return p;
  }

  @override
  Future<List<PacmanPackageData>> installedPackages() async {
    installedPackagesCalls += 1;
    return installedPackagesScript;
  }

  @override
  Future<bool> isInstalled(String name) async => installedNames.contains(name);

  @override
  Future<List<PacmanPackageData>> updatesAvailable() async => updatesScript;

  @override
  Future<PacmanTransaction> install(String packageId) async {
    installCalls.add(packageId);
    if (packageId == unknownTargetId || !detailsScript.containsKey(packageId)) {
      throw PacmanNotFoundException(
        ['pkexec', 'pacman', '-S', '--', packageId],
        1,
        'error: target not found: $packageId',
      );
    }
    return scriptedTransaction(_installScript());
  }

  @override
  Future<PacmanTransaction> remove(String packageId) async {
    removeCalls.add(packageId);
    return scriptedTransaction(_installScript());
  }

  @override
  Future<PacmanTransaction> update(String packageId) async {
    updateCalls.add(packageId);
    return scriptedTransaction(_installScript());
  }
}

/// §2.1 fixture: `pacman -Q` — bulk installed enumeration.
const _qFixture = '''
firefox 146.0-1
glibc 2.42+r12+g7d1e6f5f3b0-1
docker 1:28.5.1-1
linux 6.16.8.arch1-1
yay 12.5.2-1
''';

/// §2.2 fixture: `pacman -Ss` — search blocks with a wrapped
/// description and an [installed] flag.
const _ssFixture = '''
extra/firefox 146.0-1 [installed]
    Standalone web browser from mozilla.org
extra/firefox-i18n-de 146.0-1
    German language pack for Firefox
    Provides translations for menus, dialogs and help pages
multilib/wine 10.0-1
    A compatibility layer for running Windows programs
''';

/// §2.3-shaped `-Si` block for vim (sync db).
const _siVimFixture = '''
Repository      : extra
Name            : vim
Version         : 9.1-1
Description     : Vi Improved, a highly configurable, improved version of the vi text editor
Architecture    : x86_64
URL             : https://www.vim.org
Licenses        : custom:vim
Groups          : None
Provides        : None
Depends On      : gpm  acl  glibc
Optional Deps   : None
Conflicts With  : None
Replaces        : None
Download Size   : 1720.11 KiB
Installed Size  : 4096.00 KiB
Packager        : Someone <someone@archlinux.org>
Build Date      : Fri 10 Jun 2022 01:45:12 PM UTC
Validated By    : MD5 Sum  SHA-256 Sum  Signature
''';

/// §2.4-shaped `-Qi` block for firefox: no Repository / Download Size
/// (the local db has neither) — the fallback proof.
const _qiFirefoxFixture = '''
Name            : firefox
Version         : 146.0-1
Description     : Standalone web browser from mozilla.org
Architecture    : x86_64
URL             : https://www.mozilla.org/firefox/
Licenses        : MPL-2.0
Groups          : None
Provides        : None
Depends On      : glibc  gtk3
Optional Deps   : None
Conflicts With  : None
Replaces        : None
Installed Size  : 250000.00 KiB
Packager        : Someone <someone@archlinux.org>
Build Date      : Fri 10 Jun 2022 01:45:12 PM UTC
Validated By    : MD5 Sum  SHA-256 Sum  Signature
''';

/// §2.5 fixture: `pacman -Qu` — `name oldver -> newver`.
const _quFixture = '''
firefox 146.0-1 -> 146.0.2-1
glibc 2.42+r12+g7d1e6f5f3b0-1 -> 2.43+r1+gdeadbeef-1
''';
