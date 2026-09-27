/// Scripted [FlatpakTransport] for tests. Never touches the live system.
///
/// Import via `package:backend_flatpak/testing.dart` — kept out of the
/// main barrel so production code never depends on it.
library;

import 'dart:async';

import 'package:backend_flatpak/src/transport.dart';

class StubFlatpakTransport extends FlatpakTransport {
  @override
  Future<List<String>> run(List<String> args) async {
    if (args.first == '--version') return ['Flatpak 1.14.4'];
    if (args.first == 'info' && args.contains('--show-permissions')) {
      return [
        '[Context]',
        'shared=network;ipc;',
        'sockets=x11;wayland;',
        'devices=dri;',
      ];
    }
    if (args.first == 'info') {
      final ref = args.last;
      if (ref.contains('org.test.Installed')) {
        return [
          'Name: Test Installed',
          'ID: org.test.Installed',
          'Version: 2.0',
          'Summary: an installed app',
        ];
      }
      throw FlatpakCommandException(args, 1, 'error: no installed ref');
    }
    if (args.first == 'remote-info') {
      final ref = args.last;
      if (ref.contains('no.such')) {
        throw FlatpakCommandException(
          args,
          1,
          "error: No such ref 'no.such.App' in remote flathub",
        );
      }
      return [
        'Name: Test App',
        'ID: org.test.App',
        'Version: 1.0',
        'Summary: a test app',
        'Description: A longer description of the test app.',
      ];
    }
    throw FlatpakCommandException(args, 1, 'stub: unexpected run $args');
  }

  @override
  FlatpakProcess spawn(List<String> args) {
    if (args.first == 'search') {
      return StubFlatpakProcess(
        lines: [
          'Name        Description        Application ID        Version   Branch   Remotes',
          'Test App    a test app         org.test.App          1.0       stable   flathub',
        ],
        scriptedExitCode: 0,
      );
    }
    if (args.first == 'install') {
      return StubFlatpakProcess(
        lines: [
          'Downloading: 10%',
          'Downloading: 45% (12.3 MB / 27.5 MB)',
          'Downloading: 90% (24.7 MB / 27.5 MB)',
        ],
        lineDelay: const Duration(milliseconds: 120),
        scriptedExitCode: 0,
      );
    }
    if (args.first == 'uninstall' || args.first == 'update') {
      return StubFlatpakProcess(
        lines: ['Downloading: 50%'],
        scriptedExitCode: 0,
      );
    }
    return StubFlatpakProcess(
      lines: const [],
      scriptedExitCode: 1,
      stderr: 'stub: unexpected spawn $args',
    );
  }
}

class StubFlatpakProcess implements FlatpakProcess {
  StubFlatpakProcess({
    required this.lines,
    this.lineDelay = const Duration(milliseconds: 50),
    required this.scriptedExitCode,
    this.stderr = '',
  }) {
    unawaited(_run());
  }

  final List<String> lines;
  final Duration lineDelay;
  final int scriptedExitCode;
  final String stderr;

  final _stdout = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  var _terminated = false;

  Future<void> _run() async {
    for (final line in lines) {
      await Future<void>.delayed(lineDelay);
      if (_terminated) break;
      _stdout.add(line);
    }
    await _stdout.close();
    if (!_exitCode.isCompleted) _exitCode.complete(scriptedExitCode);
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines =>
      stderr.isEmpty ? const Stream.empty() : Stream.value(stderr);

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> terminate({Duration grace = const Duration(seconds: 2)}) async {
    _terminated = true;
    if (!_exitCode.isCompleted) _exitCode.complete(143);
  }
}
