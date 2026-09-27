import 'dart:async';

import 'package:backend_pacman/backend_pacman.dart';
import 'package:backend_pacman/src/handle.dart';
import 'package:backend_pacman/testing.dart';
import 'package:store_contracts/exam.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

const _installId = StubPacmanTransport.installTargetId;
const _installedId = StubPacmanTransport.installedTargetId;
const _unknownId = StubPacmanTransport.unknownTargetId;

AppIdentity _id(String nativeId) =>
    AppIdentity(backendId: 'pacman', nativeId: nativeId);

BackendPacman _create() => BackendPacman(transport: StubPacmanTransport());

Future<OperationState> _driveToTerminal(OperationHandle handle) async {
  final sub = handle.state.listen((_) {});
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!handle.current.isTerminal) {
      if (DateTime.now().isAfter(deadline)) {
        fail('no terminal state; stuck at ${handle.current.runtimeType}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return handle.current;
  } finally {
    await sub.cancel();
  }
}

/// A stub whose search always fails with [failure], for error-mapping
/// tests.
/// Runs a search that must throw; returns the thrown error.
Future<Object> _searchError(BackendPacman backend) async {
  try {
    await backend.search('x').toList();
  } catch (e) {
    return e;
  }
  fail('expected the search to throw');
}

class _FailingSearchTransport extends StubPacmanTransport {
  _FailingSearchTransport(this.failure);

  final PacmanTransportException failure;

  @override
  Future<List<PacmanPackageData>> search(String query) async => throw failure;
}

void main() {
  group('pacman backend', () {
    test('passes the full contract exam', () async {
      await runContractExam(
        'pacman',
        _create,
        installTarget: _id(_installId),
        unknownTarget: _id(_unknownId),
        installedTarget: _id(_installedId),
      );
    });

    test('id is pacman and contractVersion matches store_contracts', () {
      final backend = _create();
      expect(backend.id, 'pacman');
      expect(backend.contractVersion, storeContractsMajor);
    });

    test('capabilities are exactly the LLD set', () {
      final backend = _create();
      expect(backend.capabilities, {
        BackendCapability.search,
        BackendCapability.details,
        BackendCapability.install,
        BackendCapability.remove,
        BackendCapability.update,
        BackendCapability.permissions,
      });
    });

    test(
      'listInstalled is exactly one CLI call; ids carry the -Q shape',
      () async {
        final transport = StubPacmanTransport();
        final backend = BackendPacman(transport: transport);
        final apps = await backend.listInstalled();
        // The §2.1 fixture: 5 packages, one invocation, never N+1.
        expect(apps, hasLength(5));
        expect(transport.installedPackagesCalls, 1);
        for (final app in apps) {
          expect(app.identity.backendId, 'pacman');
          // Labeling honesty (research D10): never labeled deb.
          expect(app.source, AppSource.pacman);
          expect(app.isInstalled, isTrue);
          // The -Q path has no repo/arch columns.
          final pid = PacmanPackageId.parse(app.identity.nativeId);
          expect(pid.arch, isEmpty);
          expect(pid.repo, isEmpty);
        }
        final byName = {for (final a in apps) a.name: a};
        // Epoch prefix carried verbatim (research §3).
        expect(byName['docker']!.installedVersion, '1:28.5.1-1');
        expect(byName['docker']!.version, '1:28.5.1-1');
        expect(byName['yay']!.installedVersion, '12.5.2-1');
      },
    );

    test('search returns one card per header block', () async {
      final backend = _create();
      final results = await backend.search('firefox').toList();
      expect(results, hasLength(3));
      final byName = {for (final r in results) r.name: r};
      for (final r in results) {
        expect(r.source, AppSource.pacman);
      }
      // The [installed] flag survives parsing.
      expect(byName['firefox']!.isInstalled, isTrue);
      expect(byName['wine']!.isInstalled, isFalse);
      // Wrapped descriptions are joined, not truncated.
      expect(
        byName['firefox-i18n-de']!.summary,
        'German language pack for Firefox',
      );
      expect(await backend.search('zzz-no-such-app').toList(), isEmpty);
    });

    test('getDetails via -Si; -Qi fallback for foreign packages', () async {
      final backend = _create();
      final vim = await backend.getDetails(_id(_installId));
      expect(vim.app.source, AppSource.pacman);
      expect(vim.license, 'custom:vim');
      expect(vim.homepage, 'https://www.vim.org');
      expect(vim.app.version, displayVersion('9.1-1'));
      // The -Qi fixture has no Repository/Download Size columns —
      // the local-db shape carries none (research §2.4).
      final firefox = await backend.getDetails(_id(_installedId));
      expect(firefox.app.source, AppSource.pacman);
      expect(firefox.app.isInstalled, isTrue);
      expect(firefox.app.installedVersion, '146.0-1');
    });

    test('getDetails of unknown id throws AppNotFoundException', () async {
      final backend = _create();
      expect(
        () => backend.getDetails(_id(_unknownId)),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('getDetails passes the existing URL through as the signal', () async {
      final backend = _create();
      final vim = await backend.getDetails(_id(_installId));
      expect(vim.app.identitySignal!.homepageUrl, 'https://www.vim.org');
      final firefox = await backend.getDetails(_id(_installedId));
      expect(
        firefox.app.identitySignal!.homepageUrl,
        'https://www.mozilla.org/firefox/',
      );
    });

    test(
      'search/listInstalled wire formats have no URL: signal is null',
      () async {
        final backend = _create();
        for (final r in await backend.search('firefox').toList()) {
          expect(r.identitySignal, isNull);
        }
        for (final a in await backend.listInstalled()) {
          expect(a.identitySignal, isNull);
        }
      },
    );

    test('getDetails of corrupt id throws AppNotFoundException', () async {
      final backend = _create();
      expect(
        () => backend.getDetails(_id('not-an-id')),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('install on installed name is a noop, no transaction', () async {
      final transport = StubPacmanTransport();
      final backend = BackendPacman(transport: transport);
      final terminal = await _driveToTerminal(
        await backend.install(_id(_installedId)),
      );
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.noop, isTrue);
      expect(transport.installCalls, isEmpty);
    });

    test('install with corrupt id is typed, not a raw throw', () async {
      final backend = _create();
      expect(
        () => backend.install(_id('garbage')),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('remove of a not-installed name is a noop, no transaction', () async {
      final transport = StubPacmanTransport();
      final backend = BackendPacman(transport: transport);
      final terminal = await _driveToTerminal(
        await backend.remove(_id(_installId)), // vim is not installed
      );
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.noop, isTrue);
      expect(transport.removeCalls, isEmpty);
    });

    test('update with empty update list is a noop, no transaction', () async {
      final transport = StubPacmanTransport()..updatesScript = [];
      final backend = BackendPacman(transport: transport);
      final terminal = await _driveToTerminal(
        await backend.update(_id(_installedId)),
      );
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.noop, isTrue);
      expect(transport.updateCalls, isEmpty);
    });

    test(
      'checkUpdates maps old -> new versions; recoverInFlight is empty',
      () async {
        final backend = _create();
        final updates = await backend.checkUpdates();
        expect(updates, hasLength(2));
        final firefox = updates.firstWhere((u) => u.name == 'firefox');
        expect(firefox.identity.backendId, 'pacman');
        expect(firefox.fromVersion, '146.0-1');
        expect(firefox.toVersion, '146.0.2-1');
        expect(await backend.recoverInFlight(), isEmpty);
      },
    );
  });

  group('package-id parser', () {
    test('accepts 4 tokens and splits the fields', () {
      final id = PacmanPackageId.parse('vim;9.1-1;x86_64;extra');
      expect(id.name, 'vim');
      expect(id.version, '9.1-1');
      expect(id.arch, 'x86_64');
      expect(id.repo, 'extra');
      expect(id.cardKey, 'vim');
    });

    test('accepts empty arch/repo (the -Q path)', () {
      final id = PacmanPackageId.parse('firefox;146.0-1;;');
      expect(id.arch, isEmpty);
      expect(id.repo, isEmpty);
      expect(id.target, 'firefox');
    });

    test('rejects 3-token and 5-token ids', () {
      expect(
        () => PacmanPackageId.parse('vim;9.1-1;x86_64'),
        throwsFormatException,
      );
      expect(() => PacmanPackageId.parse('a;b;c;d;e'), throwsFormatException);
    });

    test('rejects empty names, empty strings, and garbage', () {
      expect(() => PacmanPackageId.parse(''), throwsFormatException);
      expect(
        () => PacmanPackageId.parse(';9.1-1;x86_64;extra'),
        throwsFormatException,
      );
      expect(() => PacmanPackageId.parse('not-an-id'), throwsFormatException);
    });

    test('version is carried verbatim, never split', () {
      // Epoch form: string surgery would corrupt identity (research §3).
      final epoch = PacmanPackageId.parse('docker;1:28.5.1-1;;');
      expect(epoch.version, '1:28.5.1-1');
      final empty = PacmanPackageId.parse('foo;;;');
      expect(empty.version, isEmpty);
    });

    test('target pins the repo when known, bare name otherwise', () {
      expect(
        PacmanPackageId.parse('vim;9.1-1;x86_64;extra').target,
        'extra/vim',
      );
      expect(PacmanPackageId.parse('vim;9.1-1;;').target, 'vim');
    });

    test('verbatim round-trip and cardKey == name', () {
      const raw = 'vim;9.1-1;x86_64;extra';
      final id = PacmanPackageId.parse(raw);
      expect(id.toString(), raw);
      expect(id.cardKey, 'vim');
      expect(parsePackageId(raw).cardKey, 'vim');
      expect(displaySubtitle('vim'), 'vim');
    });
  });

  group('output parsers', () {
    test('-Q splits on the first space and skips garbage', () {
      final packages = parseQOutput(
        'firefox 146.0-1\n'
        'garbage-without-space\n'
        '\n'
        'docker 1:28.5.1-1\n'
        'noversion \n',
      );
      expect(packages.map((p) => p.name), ['firefox', 'docker']);
      expect(packages[1].version, '1:28.5.1-1');
      expect(packages[1].installedVersion, '1:28.5.1-1');
      // Skip-on-garbage is never fatal: the list still parses.
      expect(packages, hasLength(2));
    });

    test('-Ss header regex, continuation join, [installed] flag', () {
      final results = parseSearchOutput(
        'extra/firefox 146.0-1 [installed]\n'
        '    Standalone web browser from mozilla.org\n'
        'extra/firefox-i18n-de 146.0-1\n'
        '    German language pack for Firefox\n'
        '    Provides translations for menus, dialogs and help pages\n'
        'this line is garbage\n'
        'multilib/wine 10.0-1\n'
        '    A compatibility layer for running Windows programs\n',
      );
      expect(results, hasLength(3));
      expect(results[0].installed, isTrue);
      expect(results[0].repo, 'extra');
      expect(results[1].installed, isFalse);
      expect(
        results[1].description,
        'German language pack for Firefox\n'
        'Provides translations for menus, dialogs and help pages',
      );
      expect(results[1].summary, 'German language pack for Firefox');
      // The garbage line ended firefox-i18n-de's block without failing.
      expect(results[2].name, 'wine');
      expect(results[2].repo, 'multilib');
    });

    test('-Si field map, continuation lines, Name post-filter', () {
      final hit = parseInfoOutput(
        'Repository      : extra\n'
            'Name            : nginx\n'
            'Version         : 1.29.1-1\n'
            'Description     : Lightweight HTTP server\n'
            '    and IMAP/POP3 proxy server\n'
            'Architecture    : x86_64\n'
            'URL             : https://nginx.org\n'
            'Licenses        : custom\n'
            'Download Size   : 585.77 KiB\n'
            'Installed Size  : 1693.74 KiB\n'
            '\n'
            'Repository      : extra\n'
            'Name            : nginx-mainline\n'
            'Version         : 1.29.1-1\n',
        'nginx',
        installed: false,
      )!;
      expect(hit.version, '1.29.1-1');
      expect(hit.arch, 'x86_64');
      expect(hit.repo, 'extra');
      expect(
        hit.description,
        'Lightweight HTTP server\nand IMAP/POP3 proxy server',
      );
      expect(hit.url, 'https://nginx.org');
      expect(hit.license, 'custom');
      expect(hit.downloadSize, parseSize('585.77 KiB'));
      expect(hit.installed, isFalse);
      // The regex-arg guard: no exact Name block → null.
      expect(
        parseInfoOutput(
          'Name            : nginx-mainline\n',
          'nginx',
          installed: false,
        ),
        isNull,
      );
    });

    test('-Qu old -> new, [...] drop, garbage skip', () {
      final updates = parseUpdateLines(
        'firefox 146.0-1 -> 146.0.2-1\n'
        'ignored-pkg 1.0-1 -> 2.0-1 [ignored]\n'
        'not a version line\n'
        'glibc 2.42-1 -> 2.43-1\n',
      );
      expect(updates, hasLength(2));
      expect(updates[0].name, 'firefox');
      expect(updates[0].version, '146.0.2-1');
      expect(updates[0].installedVersion, '146.0-1');
      expect(updates[0].installed, isTrue);
      expect(updates[1].name, 'glibc');
    });

    test('parseSize handles B/KiB/MiB/GiB and never throws', () {
      expect(parseSize('585.77 KiB'), 599828);
      expect(parseSize('1693.74 KiB'), greaterThan(1700000));
      expect(parseSize('1.71 MiB'), 1793065);
      expect(parseSize('2.10 GiB'), 2254857830);
      expect(parseSize('512 B'), 512);
      expect(parseSize('1.5 kib'), 1536);
      expect(parseSize('nonsense'), 0);
      expect(parseSize('10 XB'), 0);
      expect(parseSize(null), 0);
      expect(parseSize(''), 0);
      expect(displayVersion('1:28.5.1-1'), '1:28.5.1-1');
      expect(displayVersion(''), isNull);
    });

    test('search query is escaped to a literal regex', () {
      expect(escapeSearchQuery('c++'), RegExp.escape('c++'));
      final re = RegExp(escapeSearchQuery('a.b'));
      expect(re.hasMatch('a.b'), isTrue);
      expect(re.hasMatch('axb'), isFalse);
    });

    test('transaction line classifier maps the §2.7 fixture', () {
      final c = TxLineClassifier();
      expect(
        c.classifyStdout('resolving dependencies...')!.phase,
        PacmanTxPhase.preparing,
      );
      expect(
        c.classifyStdout('looking for conflicting packages...')!.phase,
        PacmanTxPhase.preparing,
      );
      expect(
        c.classifyStdout('Packages (2) libutil-linux-2.41.2-1')!.phase,
        PacmanTxPhase.preparing,
      );
      final sizeEvent = c.classifyStdout('Total Download Size:   1.71 MiB')!;
      expect(sizeEvent.phase, PacmanTxPhase.preparing);
      expect(sizeEvent.bytesTotal, parseSize('1.71 MiB'));
      expect(
        c.classifyStdout(':: Retrieving packages...')!.phase,
        PacmanTxPhase.downloading,
      );
      expect(
        c.classifyStdout('archinstall-3.0.5-1-any downloading...')!.phase,
        PacmanTxPhase.downloading,
      );
      expect(
        c.classifyStdout('checking keyring...')!.phase,
        PacmanTxPhase.verifying,
      );
      expect(
        c.classifyStdout('checking package integrity...')!.phase,
        PacmanTxPhase.verifying,
      );
      expect(
        c.classifyStdout(':: Processing package changes...')!.phase,
        PacmanTxPhase.applying,
      );
      final nm = c.classifyStdout('(1/2) installing foo...')!;
      expect(nm.phase, PacmanTxPhase.applying);
      expect(nm.fraction, 0.5);
      // Unclassified lines: null event, but the pulse keeps liveness
      // on the last classified phase.
      expect(c.classifyStdout(':: Proceed with installation? [Y/n]'), isNull);
      expect(c.pulse().phase, PacmanTxPhase.applying);
      expect(c.pulse().fraction, 0.5);
    });
  });

  group('checkupdates vs -Qu', () {
    const quStdout = 'firefox 146.0-1 -> 146.0.2-1\n';

    test('checkupdates exit 0 parses, exit 2 is empty', () {
      expect(updatesFromCheckupdates(0, quStdout, ''), hasLength(1));
      expect(updatesFromCheckupdates(2, '', ''), isEmpty);
    });

    test('checkupdates exit 1 is a typed transport error', () {
      expect(
        () => updatesFromCheckupdates(1, '', 'ERROR: Cannot fetch updates'),
        throwsA(isA<PacmanTransportException>()),
      );
    });

    test('-Qu exit 1 with empty stdout is "no updates", not an error', () {
      expect(updatesFromQu(1, '', ''), isEmpty);
    });

    test('-Qu exit 1 with stderr text is a typed error', () {
      expect(
        () => updatesFromQu(
          1,
          '',
          'error: failed to synchronize all databases (unexpected error)',
        ),
        throwsA(isA<PacmanTransportException>()),
      );
    });

    test('-Qu exit 0 parses; other codes throw', () {
      expect(updatesFromQu(0, quStdout, ''), hasLength(1));
      expect(
        () => updatesFromQu(3, '', 'weird'),
        throwsA(isA<PacmanTransportException>()),
      );
    });
  });

  group('error mapping', () {
    test('PacmanNotFoundException becomes AppNotFoundException', () async {
      final backend = _create();
      expect(
        () => backend.install(_id(_unknownId)),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('missing pacman binary becomes BackendUnavailableException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman', '--version'],
            127,
            'pacman not found: stub',
          ),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test(
      'missing pkexec becomes PermissionException with remediation',
      () async {
        final backend = BackendPacman(
          transport: _FailingSearchTransport(
            PacmanTransportException(
              ['pkexec', 'pacman'],
              127,
              'pkexec not found: polkit not installed',
            ),
          ),
        );
        final error = await _searchError(backend);
        expect(error, isA<PermissionException>());
        expect(
          (error as PermissionException).neededAccess,
          contains('install polkit'),
        );
      },
    );

    test('rootless stderr becomes PermissionException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman', '-S'],
            1,
            'error: you cannot perform this operation unless you are root.',
          ),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<PermissionException>()),
      );
    });

    test('target-not-found becomes AppNotFoundException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman', '-S'],
            1,
            'error: target not found: no-such-pkg',
          ),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<AppNotFoundException>()),
      );
    });

    test('db lock and conflicting files become ConflictException', () async {
      for (final stderr in [
        'error: failed to init transaction (unable to lock database)',
        'error: failed to commit transaction (conflicting files)',
      ]) {
        final backend = BackendPacman(
          transport: _FailingSearchTransport(
            PacmanTransportException(['pacman'], 1, stderr),
          ),
        );
        expect(
          () => backend.search('x').toList(),
          throwsA(isA<ConflictException>()),
          reason: stderr,
        );
      }
    });

    test('unsatisfied deps become DependencyException with details', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman'],
            1,
            'error: failed to prepare transaction '
            '(could not satisfy dependencies)\n'
            ":: installing vim breaks dependency 'xxd' required by gvim",
          ),
        ),
      );
      final error = await _searchError(backend);
      expect(error, isA<DependencyException>());
      expect((error as DependencyException).details, contains('xxd'));
    });

    test('mirror failures become NetworkException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman'],
            1,
            "error: failed retrieving file 'foo.db' from mirror : "
            'Could not resolve host',
          ),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<NetworkException>()),
      );
    });

    test('checkupdates fetch failure becomes NetworkException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['checkupdates'],
            1,
            'ERROR: Cannot fetch updates',
          ),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<NetworkException>()),
      );
    });

    test('full disk becomes DiskSpaceException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman'],
            1,
            'error: Partition / too full: 1234 blocks needed',
          ),
        ),
      );
      final error = await _searchError(backend);
      expect(error, isA<DiskSpaceException>());
      expect((error as DiskSpaceException).neededBytes, -1);
    });

    test('bad signatures become VerificationException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(
            ['pacman'],
            1,
            'error: foo: signature from "Someone" is invalid',
          ),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<VerificationException>()),
      );
    });

    test('unknown failures become UnknownStoreException', () async {
      final backend = BackendPacman(
        transport: _FailingSearchTransport(
          PacmanTransportException(['pacman'], 1, 'something nobody foresaw'),
        ),
      );
      expect(
        () => backend.search('x').toList(),
        throwsA(isA<UnknownStoreException>()),
      );
    });
  });

  group('cancel semantics', () {
    PacmanOperationHandle _handle(
      StreamController<PacmanTxEvent> controller, {
      Duration heartbeatInterval = const Duration(seconds: 60),
      // The real CliPacmanTransport never closes the event stream
      // silently: killing the child always surfaces as a terminal
      // PacmanTxDone(cancelledByUs: true). The default mimics that.
      Future<void> Function()? onCancel,
    }) => PacmanOperationHandle(
      app: _id(_installId),
      kind: OperationKind.install,
      transaction: PacmanTransaction(
        events: controller.stream,
        cancel:
            onCancel ??
            () async {
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
      ),
      mapError: (e) =>
          UnknownStoreException(debugDetail: e.stderr, backendId: 'pacman'),
      heartbeatInterval: heartbeatInterval,
    );

    test(
      'cancel during applying: cancelling <=2s, then cancelled, never failed',
      () async {
        final controller = StreamController<PacmanTxEvent>();
        final handle = _handle(controller);
        final states = <OperationState>[];
        final sub = handle.state.listen(states.add);
        // Drive to a cancellable phase.
        controller.add(
          const PacmanTxProgress(phase: PacmanTxPhase.applying, fraction: 0.5),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (handle.current is! Applying) {
          if (DateTime.now().isAfter(deadline)) {
            fail('never reached applying');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final sw = Stopwatch()..start();
        await handle.cancel();
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(2000));
        final terminal = await _driveToTerminal(handle);
        await sub.cancel();
        expect(terminal, isA<Cancelled>());
        expect(states.any((s) => s is Cancelling), isTrue);
        expect(states.any((s) => s is Failed), isFalse);
      },
    );

    test('kill-after-commit: done with cancelRequested: true', () async {
      final controller = StreamController<PacmanTxEvent>();
      // The SIGTERM lands but pacman is past the point of no return:
      // cancel() signals only — the process still reports exit 0.
      final handle = _handle(controller, onCancel: () async {});
      final states = <OperationState>[];
      final sub = handle.state.listen(states.add);
      controller.add(
        const PacmanTxProgress(phase: PacmanTxPhase.applying, fraction: 0.9),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (handle.current is! Applying) {
        if (DateTime.now().isAfter(deadline)) fail('never reached applying');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // pacman committed before the signal landed: exit 0 even though
      // we asked for a cancel (research §8).
      await handle.cancel();
      controller.add(
        const PacmanTxDone(exitCode: 0, stderr: '', cancelledByUs: true),
      );
      await controller.close();
      final terminal = await _driveToTerminal(handle);
      await sub.cancel();
      expect(terminal, isA<Done>());
      expect((terminal as Done).result.cancelRequested, isTrue);
    });

    test(
      'heartbeat re-emits a silent downloading phase; stops at terminal',
      () async {
        final controller = StreamController<PacmanTxEvent>();
        final handle = _handle(
          controller,
          heartbeatInterval: const Duration(milliseconds: 60),
        );
        final states = <OperationState>[];
        final sub = handle.state.listen(states.add);
        final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);

        controller.add(
          const PacmanTxProgress(phase: PacmanTxPhase.downloading),
        );
        // Silent phase: no transport events for well over the interval.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        controller.add(const PacmanTxDone(exitCode: 0, stderr: ''));
        await controller.close();

        final terminal = await terminalFuture.timeout(
          const Duration(seconds: 10),
        );
        // Quiet window: the heartbeat must not emit after the terminal.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await sub.cancel();

        expect(terminal, isA<Done>());
        final downloads = states.whereType<Downloading>().toList();
        expect(
          downloads.length,
          greaterThan(1),
          reason: 'the silent downloading phase must be re-emitted',
        );
        for (final d in downloads) {
          expect(d.bytesDone, 0);
          // Indeterminate download: no fabricated byte counts.
          expect(d.bytesTotal, isNull);
        }
        expect(
          states.indexOf(terminal),
          states.length - 1,
          reason: 'no emission after the terminal state',
        );
      },
    );

    test('pkexec exit 126 is a quiet AuthException(dismissed)', () async {
      final controller = StreamController<PacmanTxEvent>();
      final handle = _handle(controller);
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);
      controller.add(const PacmanTxDone(exitCode: 126, stderr: ''));
      await controller.close();
      final terminal = await terminalFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(terminal, isA<Failed>());
      final error = (terminal as Failed).error;
      expect(error, isA<AuthException>());
      expect((error as AuthException).kind, AuthKind.dismissed);
    });

    test('pkexec exit 127 is a PermissionException', () async {
      final controller = StreamController<PacmanTxEvent>();
      final handle = _handle(controller);
      final terminalFuture = handle.state.firstWhere((s) => s.isTerminal);
      controller.add(
        const PacmanTxDone(
          exitCode: 127,
          stderr: 'Error executing command as another user: Not authorized',
        ),
      );
      await controller.close();
      final terminal = await terminalFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(terminal, isA<Failed>());
      expect((terminal as Failed).error, isA<PermissionException>());
    });
  });
}
