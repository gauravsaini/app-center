/// [CliPacmanTransport]: the production [PacmanTransport], shelling
/// out to the `pacman(1)` binary (and `checkupdates` from
/// pacman-contrib). Mirrors flatpak's `CliFlatpakTransport`
/// run/spawn/terminate shape.
///
/// Read invocations (`--version`, `-Q`, `-Ss`, `-Si`, `-Qi`, `-Qu`,
/// `checkupdates`) run root-free; only the three mutating spawns go
/// through `pkexec`. All parsing lives in the top-level `parse*`
/// functions below so the exam can pin the wire shapes without
/// spawning processes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'metadata.dart';
import 'transport.dart';

/// Escape a user search query into a literal regex: `-Ss` arguments
/// are POSIX regexes, and unescaped input would be a correctness bug
/// and a ReDoS-adjacent footgun (research D12).
String escapeSearchQuery(String query) => RegExp.escape(query);

/// Parse `pacman -Q` output (research §2.1): one `name<space>version`
/// per line. Splits on the FIRST space; the version is opaque and may
/// carry an epoch prefix (`1:28.5.1-1`). Unparseable lines are
/// skipped, never fatal — the invocation failing is the only error.
List<PacmanPackageData> parseQOutput(String stdout) {
  final packages = <PacmanPackageData>[];
  for (final rawLine in stdout.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final i = line.indexOf(' ');
    if (i < 0) continue; // skip, never fail the list
    final name = line.substring(0, i);
    final version = line.substring(i + 1).trim();
    if (name.isEmpty || version.isEmpty) continue; // skip
    packages.add(
      PacmanPackageData(
        id: PacmanPackageId(
          name: name,
          version: version,
          arch: '',
          repo: '',
        ).toString(),
        name: name,
        version: version,
        arch: '',
        repo: '',
        summary: '', // descriptions are a getDetails() concern (HLD §3)
        installed: true,
        installedVersion: version,
      ),
    );
  }
  return packages;
}

final _ssHeader = RegExp(r'^([^/\s]+)/([^\s]+)\s+([^\s]+)(?:\s+\[(.*)\])?$');

/// Parse `pacman -Ss` output (research §2.2): `repo/name version
/// [flags]` header lines followed by indented description lines
/// (which WRAP — continuation lines are joined, not dropped).
/// `[installed]` marks an installed package; any `[...]` suffix is
/// accepted without interpreting its contents.
List<PacmanPackageData> parseSearchOutput(String stdout) {
  final results = <PacmanPackageData>[];
  String? repo;
  String? name;
  String? version;
  var installed = false;
  final descLines = <String>[];

  void flush() {
    final n = name;
    final v = version;
    final r = repo;
    // A header always sets all three; a defensive null here keeps a
    // corrupt line from poisoning the whole search result.
    if (n == null || v == null || r == null) return;
    results.add(
      PacmanPackageData(
        id: PacmanPackageId(
          name: n,
          version: v,
          arch: '', // -Ss has no arch column; getDetails fills it
          repo: r,
        ).toString(),
        name: n,
        version: v,
        arch: '',
        repo: r,
        summary: descLines.isEmpty ? '' : descLines.first,
        description: descLines.join('\n'),
        installed: installed,
      ),
    );
    name = null;
    descLines.clear();
  }

  for (final rawLine in stdout.split('\n')) {
    final m = _ssHeader.firstMatch(rawLine);
    if (m != null) {
      flush();
      repo = m.group(1)!;
      name = m.group(2)!;
      version = m.group(3)!;
      installed = m.group(4) != null;
    } else if (rawLine.trim().isEmpty) {
      continue; // blank lines never split a block
    } else if (name != null &&
        (rawLine.startsWith(' ') || rawLine.startsWith('\t'))) {
      descLines.add(rawLine.trim());
    } else {
      flush(); // garbage line: end the block, never fail the search
    }
  }
  flush();
  return results;
}

final _infoField = RegExp(r'^([^:]+?)\s*:\s*(.*)$');

/// Parse one `-Si`/`-Qi` info block (research §2.3–2.4): `Key : value`
/// lines, two-space continuation lines, blocks separated by blank
/// lines. Post-filters on `Name:` (the `-Si` argument is a regex, so
/// the first block is not necessarily ours). Returns null when no
/// block matches [name].
PacmanPackageData? parseInfoOutput(
  String stdout,
  String name, {
  required bool installed,
}) {
  for (final block in stdout.split('\n\n')) {
    final fields = <String, String>{};
    String? currentKey;
    for (final line in block.split('\n')) {
      final m = _infoField.firstMatch(line);
      if (m != null) {
        currentKey = m.group(1)!.trim();
        fields[currentKey] = m.group(2)!.trim();
      } else if (currentKey != null &&
          (line.startsWith('  ') || line.startsWith('\t')) &&
          line.trim().isNotEmpty) {
        fields[currentKey] = '${fields[currentKey]}\n${line.trim()}';
      }
    }
    if (fields['Name'] != name) continue; // regex-arg guard
    final version = fields['Version'] ?? '';
    final arch = fields['Architecture'] ?? '';
    final repo = fields['Repository'] ?? '';
    return PacmanPackageData(
      id: PacmanPackageId(
        name: name,
        version: version,
        arch: arch,
        repo: repo,
      ).toString(),
      name: name,
      version: version,
      arch: arch,
      repo: repo,
      summary: fields['Description'] ?? '',
      description: fields['Description'] ?? '',
      url: fields['URL'] ?? '',
      license: fields['Licenses'] ?? '',
      downloadSize: parseSize(fields['Download Size']),
      installSize: parseSize(fields['Installed Size']),
      installed: installed,
    );
  }
  return null;
}

final _quLine = RegExp(r'^([^\s]+)\s+([^\s]+)\s+->\s+([^\s]+)$');

/// Parse `pacman -Qu` / `checkupdates` output (research §2.5–2.6):
/// `name oldver -> newver` per line. Lines carrying `[...]` markers
/// (ignored packages) are dropped, like checkupdates' own
/// `grep -v '\[.*\]'`. Each entry's [PacmanPackageData.version] is the
/// NEW version; [PacmanPackageData.installedVersion] the OLD.
List<PacmanPackageData> parseUpdateLines(String stdout) {
  final updates = <PacmanPackageData>[];
  for (var line in stdout.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    if (line.contains('[') && line.contains(']')) continue;
    final m = _quLine.firstMatch(line);
    if (m == null) continue; // skip, not fatal
    final name = m.group(1)!;
    final oldVer = m.group(2)!;
    final newVer = m.group(3)!;
    updates.add(
      PacmanPackageData(
        id: PacmanPackageId(
          name: name,
          version: newVer,
          arch: '',
          repo: '',
        ).toString(),
        name: name,
        version: newVer,
        arch: '',
        repo: '',
        summary: '',
        installed: true,
        installedVersion: oldVer,
      ),
    );
  }
  return updates;
}

/// The `checkupdates` exit-code table (research §2.6): 0 → parse,
/// 2 → [] (no updates, normal), 1 → typed error from stderr.
/// Pure so the exam can pin the disambiguation without processes.
List<PacmanPackageData> updatesFromCheckupdates(
  int exitCode,
  String stdout,
  String stderr,
) {
  switch (exitCode) {
    case 0:
      return parseUpdateLines(stdout);
    case 2:
      return const [];
    default:
      throw PacmanTransportException(['checkupdates'], exitCode, stderr.trim());
  }
}

/// The `pacman -Qu` exit-code quirk (research §2.5): exit 1 means BOTH
/// "no updates" and real errors, so the code is never mapped alone —
/// stdout/stderr disambiguate. Pure so the exam can pin it.
List<PacmanPackageData> updatesFromQu(
  int exitCode,
  String stdout,
  String stderr,
) {
  if (exitCode == 0) return parseUpdateLines(stdout);
  if (exitCode == 1) {
    if (stderr.trim().isNotEmpty) {
      throw PacmanTransportException(
        ['pacman', '-Qu'],
        exitCode,
        stderr.trim(),
      );
    }
    if (stdout.trim().isEmpty) return const []; // no updates: normal
    return parseUpdateLines(stdout);
  }
  throw PacmanTransportException(['pacman', '-Qu'], exitCode, stderr.trim());
}

/// Exit-1 "not found" shapes: `pacman -Q/-Si/-Qi` print
/// `error: package '<name>' was not found.` on stderr (research §2.1,
/// §2.3); an empty stderr with exit 1 is the same signal.
bool _looksLikeNotFound(int exitCode, String stderr) =>
    exitCode == 1 &&
    (stderr.trim().isEmpty || stderr.toLowerCase().contains('was not found'));

/// Classifies mutating-transaction stdout lines into [PacmanTxPhase]
/// (LLD §5). Regex-tolerant: the fixtures are reconstructed, so the
/// classifier must not depend on exact spacing. First match wins.
class TxLineClassifier {
  PacmanTxPhase _phase = PacmanTxPhase.authenticating;
  int? _bytesTotal;
  double? _fraction;

  static final _totalSize = RegExp(
    r'Total Download Size:\s*([\d.]+\s*[KMGT]?i?B)',
    caseSensitive: false,
  );
  static final _nOfM = RegExp(
    r'^\((\d+)/(\d+)\)\s+(installing|upgrading|removing|checking)\b',
  );
  static final _retrieving = RegExp(r'^:: Retrieving packages');
  static final _downloading = RegExp(r' downloading\.\.\.\s*$');
  static final _verifying = RegExp(r'^checking (keyring|package integrity)');
  static final _processing = RegExp(
    r'^:: (Processing package changes|Running post-transaction hooks)',
  );
  static final _preparing = RegExp(
    r'^(resolving dependencies|looking for conflicting|Packages \(\d+\))',
  );

  /// Classify one stdout [line]. Returns a progress event, or null
  /// when the line is unclassified (the caller then emits [pulse] —
  /// every line is liveness, even the ones we don't understand).
  PacmanTxProgress? classifyStdout(String line) {
    var m = _totalSize.firstMatch(line);
    if (m != null) {
      // The summary line keeps the phase at preparing; bytesTotal is
      // latched for the download phase.
      _bytesTotal = parseSize(m.group(1));
      _phase = PacmanTxPhase.preparing;
      return _progress();
    }
    m = _nOfM.firstMatch(line);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      final d = int.parse(m.group(2)!);
      if (d > 0) {
        final f = (n / d).clamp(0.0, 1.0);
        // Monotonic per transaction: never let a reordered line move
        // the fraction backwards.
        if (_fraction == null || f >= _fraction!) _fraction = f;
      }
      _phase = PacmanTxPhase.applying;
      return _progress();
    }
    if (_retrieving.hasMatch(line) || _downloading.hasMatch(line)) {
      _phase = PacmanTxPhase.downloading;
      return _progress();
    }
    if (_verifying.hasMatch(line)) {
      _phase = PacmanTxPhase.verifying;
      return _progress();
    }
    if (_processing.hasMatch(line)) {
      _phase = PacmanTxPhase.applying;
      return _progress();
    }
    if (_preparing.hasMatch(line)) {
      _phase = PacmanTxPhase.preparing;
      return _progress();
    }
    return null;
  }

  /// Liveness pulse: the current phase with no new information. The
  /// handle marks the heartbeat on these without emitting a visible
  /// state change.
  PacmanTxProgress pulse() => _progress();

  PacmanTxProgress _progress() => PacmanTxProgress(
    phase: _phase,
    bytesTotal: _bytesTotal,
    fraction: _fraction,
  );
}

class _CmdResult {
  _CmdResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Real transport: shells out to the `pacman` binary (and
/// `checkupdates` / `pkexec` where the LLD says so).
class CliPacmanTransport extends PacmanTransport {
  CliPacmanTransport({
    this.executable = 'pacman',
    this.checkupdatesExecutable = 'checkupdates',
    this.pkexecExecutable = 'pkexec',
  });

  final String executable;
  final String checkupdatesExecutable;
  final String pkexecExecutable;

  bool? _hasCheckupdates;
  _PacmanCliProcess? _activeSearch;

  /// Run [exe] with [args], capturing output. Throws
  /// [PacmanTransportException] (exit 127, `<exe> not found`) only
  /// when the process cannot start — the message names the binary so
  /// the backend can tell a missing pacman (read path,
  /// BackendUnavailable) from a missing pkexec (mutate path,
  /// PermissionException with the polkit remediation).
  Future<_CmdResult> _exec(String exe, List<String> args) async {
    late final Process p;
    try {
      p = await Process.start(exe, args);
    } on ProcessException catch (e) {
      throw PacmanTransportException(
        [exe, ...args],
        127,
        '$exe not found: ${e.message}',
      );
    }
    final out = await p.stdout.transform(utf8.decoder).join();
    final err = await p.stderr.transform(utf8.decoder).join();
    final code = await p.exitCode;
    return _CmdResult(code, out, err.trim());
  }

  /// [_exec] that throws [PacmanTransportException] on non-zero exit.
  Future<_CmdResult> _run(String exe, List<String> args) async {
    final r = await _exec(exe, args);
    if (r.exitCode != 0) {
      throw PacmanTransportException([exe, ...args], r.exitCode, r.stderr);
    }
    return r;
  }

  @override
  Future<void> checkAvailable() async {
    // `pacman --version`: exit 0, root-free, no side effects
    // (research §2.10). Any failure → the backend reads unavailable.
    await _run(executable, ['--version']);
  }

  /// PATH lookup: answers exactly "is the binary present" with no
  /// subprocess and no side effects. Cached per transport instance.
  static bool _binaryOnPath(String name) {
    if (name.contains('/')) return File(name).existsSync();
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      if (File('$dir/$name').existsSync()) return true;
    }
    return false;
  }

  @override
  Future<bool> hasCheckupdates() async {
    final cached = _hasCheckupdates;
    if (cached != null) return cached;
    final present = _binaryOnPath(checkupdatesExecutable);
    _hasCheckupdates = present;
    return present;
  }

  @override
  Future<List<PacmanPackageData>> search(String query) async {
    final proc = _PacmanCliProcess(executable, [
      '-Ss',
      '--',
      escapeSearchQuery(query),
    ]);
    _activeSearch = proc;
    try {
      final out = StringBuffer();
      final err = StringBuffer();
      final outSub = proc.stdoutLines.listen(out.writeln);
      final errSub = proc.stderrLines.listen(err.writeln);
      final code = await proc.exitCode;
      await outSub.cancel();
      await errSub.cancel();
      if (code != 0) {
        throw PacmanTransportException(
          [executable, '-Ss', '--', query],
          code,
          err.toString().trim(),
        );
      }
      return parseSearchOutput(out.toString());
    } finally {
      if (identical(_activeSearch, proc)) _activeSearch = null;
    }
  }

  @override
  Future<void> cancelSearch() => _activeSearch?.terminate() ?? Future.value();

  @override
  Future<PacmanPackageData> getDetails(String packageId) async {
    final name = PacmanPackageId.parse(packageId).name;
    // Sync db first; the -Si argument is a regex, so post-filter on
    // Name: (research §2.3).
    final si = await _exec(executable, ['-Si', '--', name]);
    final hit = parseInfoOutput(si.stdout, name, installed: false);
    if (hit != null) return hit;
    if (!_looksLikeNotFound(si.exitCode, si.stderr)) {
      throw PacmanTransportException(
        [executable, '-Si', '--', name],
        si.exitCode,
        si.stderr,
      );
    }
    // Fallback: the local db (foreign/AUR-installed packages,
    // research §2.4).
    final qi = await _exec(executable, ['-Qi', '--', name]);
    final qhit = parseInfoOutput(qi.stdout, name, installed: true);
    if (qhit != null) return qhit;
    if (!_looksLikeNotFound(qi.exitCode, qi.stderr)) {
      throw PacmanTransportException(
        [executable, '-Qi', '--', name],
        qi.exitCode,
        qi.stderr,
      );
    }
    throw PacmanNotFoundException(
      [executable, '-Si/-Qi', '--', name],
      qi.exitCode,
      qi.stderr.isNotEmpty ? qi.stderr : si.stderr,
    );
  }

  @override
  Future<List<PacmanPackageData>> installedPackages() async {
    // Exactly ONE invocation (research D3): no N+1, no legacy path.
    final r = await _run(executable, ['-Q']);
    return parseQOutput(r.stdout);
  }

  @override
  Future<bool> isInstalled(String name) async {
    final r = await _exec(executable, ['-Q', '--', name]);
    if (r.exitCode == 0) return true;
    if (_looksLikeNotFound(r.exitCode, r.stderr)) return false;
    throw PacmanTransportException(
      [executable, '-Q', '--', name],
      r.exitCode,
      r.stderr,
    );
  }

  @override
  Future<List<PacmanPackageData>> updatesAvailable() async {
    // checkupdates is preferred: it syncs its own fakeroot db, so the
    // check never reads a stale db and never needs root (research §7).
    if (await hasCheckupdates()) {
      final r = await _exec(checkupdatesExecutable, const []);
      return updatesFromCheckupdates(r.exitCode, r.stdout, r.stderr);
    }
    final r = await _exec(executable, const ['-Qu']);
    return updatesFromQu(r.exitCode, r.stdout, r.stderr);
  }

  @override
  Future<PacmanTransaction> install(String packageId) async {
    // repo/name pins the repo when known, bare name otherwise
    // (research D2); --needed is belt-and-braces idempotency.
    final target = PacmanPackageId.parse(packageId).target;
    return _spawnMutate(['-S', '--needed', '--noconfirm', '--', target]);
  }

  @override
  Future<PacmanTransaction> remove(String packageId) async {
    // MVP is -R, not -Rs (HLD §2 — the cascade needs its own UX).
    final name = PacmanPackageId.parse(packageId).name;
    return _spawnMutate(['-R', '--noconfirm', '--', name]);
  }

  @override
  Future<PacmanTransaction> update(String packageId) async {
    // The package is installed (the backend noop-checked via
    // updatesAvailable), so the bare name is the right target.
    final name = PacmanPackageId.parse(packageId).name;
    return _spawnMutate(['-S', '--noconfirm', '--', name]);
  }

  /// Spawn `pkexec pacman …`, classifying the child's stdout into
  /// transaction events. The child is killable: cancel() SIGTERMs,
  /// waits 2s, SIGKILLs (research §8).
  PacmanTransaction _spawnMutate(List<String> pacmanArgs) {
    final proc = _PacmanCliProcess(pkexecExecutable, ['pacman', ...pacmanArgs]);
    final classifier = TxLineClassifier();
    final controller = StreamController<PacmanTxEvent>();
    final stderrBuf = StringBuffer();
    // Both pipes must flush before the terminal event: stderr carries
    // the error evidence the backend maps typed, and closing the
    // event controller on stdout's onDone alone can truncate it.
    final stdoutDrained = Completer<void>();
    final stderrDrained = Completer<void>();
    var cancelledByUs = false;
    var doneEmitted = false;

    Future<void> emitDone() async {
      if (doneEmitted) return;
      doneEmitted = true;
      final code = await proc.exitCode;
      // The process is dead; its pipes close right after. Wait for
      // both, bounded — a stalled pipe must never hang cancel().
      await stdoutDrained.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      await stderrDrained.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      if (!controller.isClosed) {
        controller.add(
          PacmanTxDone(
            exitCode: code,
            stderr: stderrBuf.toString().trim(),
            cancelledByUs: cancelledByUs,
          ),
        );
        await controller.close();
      }
    }

    proc.stdoutLines.listen(
      (line) {
        if (!controller.isClosed) {
          // Unclassified lines are still liveness (LLD §5).
          controller.add(classifier.classifyStdout(line) ?? classifier.pulse());
        }
      },
      onDone: () {
        if (!stdoutDrained.isCompleted) stdoutDrained.complete();
        unawaited(emitDone());
      },
    );
    proc.stderrLines.listen(
      (line) {
        stderrBuf.writeln(line);
        if (!controller.isClosed) controller.add(classifier.pulse());
      },
      onDone: () {
        if (!stderrDrained.isCompleted) stderrDrained.complete();
      },
    );

    return PacmanTransaction(
      events: controller.stream,
      cancel: () async {
        cancelledByUs = true;
        await proc.terminate();
        // Belt-and-braces: the terminal event must arrive even if a
        // stream stalled between SIGTERM and exit.
        await emitDone();
      },
    );
  }
}

/// A running pacman/pkexec child. Mirrors flatpak's `_CliProcess`:
/// line-split stdout/stderr, exit code, SIGTERM→grace→SIGKILL.
class _PacmanCliProcess implements PacmanProcess {
  _PacmanCliProcess(this.executable, this.args) {
    _start();
  }

  final String executable;
  final List<String> args;

  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exitCode = Completer<int>();
  Process? _process;

  Future<void> _start() async {
    try {
      _process = await Process.start(executable, args);
    } on ProcessException catch (e) {
      // Binary missing (no polkit on a stock Arch box): the 127 +
      // greppable message lets the backend map it typed (LLD §7).
      _stderr.add('$executable not found: ${e.message}');
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
