/// Transport abstraction: everything the backend needs from the outside
/// world. [CliFlatpakTransport] shells out to `flatpak(1)`; tests use
/// [StubFlatpakTransport] with canned responses.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Transport-level failure. The backend maps these to [StoreException];
/// they never escape the backend directly.
class FlatpakCommandException implements Exception {
  FlatpakCommandException(this.args, this.exitCode, this.stderr);

  final List<String> args;
  final int exitCode;
  final String stderr;

  @override
  String toString() => 'flatpak ${args.join(' ')} exited $exitCode: $stderr';
}

/// A running flatpak process.
abstract class FlatpakProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;

  /// SIGTERM, then SIGKILL after [grace].
  Future<void> terminate({Duration grace = const Duration(seconds: 2)});
}

abstract class FlatpakTransport {
  /// Run a short command, return stdout lines.
  /// Throws [FlatpakCommandException] on non-zero exit.
  Future<List<String>> run(List<String> args);

  /// Spawn a long-running command (install/update/remove).
  FlatpakProcess spawn(List<String> args);
}

/// Real transport: shells out to the `flatpak` binary.
class CliFlatpakTransport extends FlatpakTransport {
  CliFlatpakTransport({this.executable = 'flatpak'});

  final String executable;

  @override
  Future<List<String>> run(List<String> args) async {
    late final Process p;
    try {
      p = await Process.start(executable, args);
    } on ProcessException catch (e) {
      throw FlatpakCommandException(args, 127, e.message);
    }
    final out = await p.stdout.transform(utf8.decoder).join();
    final err = await p.stderr.transform(utf8.decoder).join();
    final code = await p.exitCode;
    if (code != 0) throw FlatpakCommandException(args, code, err.trim());
    return out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  @override
  FlatpakProcess spawn(List<String> args) => _CliProcess(executable, args);
}

class _CliProcess implements FlatpakProcess {
  _CliProcess(String executable, List<String> args) {
    _start(executable, args);
  }

  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  Process? _process;

  Future<void> _start(String executable, List<String> args) async {
    try {
      _process = await Process.start(executable, args);
    } on ProcessException catch (e) {
      _stderr.add('failed to start: ${e.message}');
      await _stderr.close();
      await _stdout.close();
      _exitCode.complete(127);
      return;
    }
    final p = _process!;
    p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stdout.add, onDone: () => _stdout.close());
    p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderr.add, onDone: () => _stderr.close());
    _exitCode.complete(await p.exitCode);
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> terminate({Duration grace = const Duration(seconds: 2)}) async {
    final p = _process;
    if (p == null || _exitCode.isCompleted) return;
    p.kill(ProcessSignal.sigterm);
    await _exitCode.future.timeout(
      grace,
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
