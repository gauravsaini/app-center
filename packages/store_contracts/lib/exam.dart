/// The backend contract exam.
///
/// Every backend MUST pass this. It is transport-agnostic: backends run it
/// with a stubbed transport (canned responses), never against the live
/// system — installing real apps in a unit test is slow, privileged, and
/// flaky. The fake backend in `test/` demonstrates the pattern.
///
/// ```dart
/// import 'package:store_contracts/exam.dart';
///
/// void main() {
///   test('flatpak passes the contract exam', () => runContractExam(
///         'flatpak',
///         () => BackendFlatpak(transport: StubTransport.canned()),
///         installTarget: const AppIdentity(backendId: 'flatpak', nativeId: 'org.test.App'),
///         unknownTarget: const AppIdentity(backendId: 'flatpak', nativeId: 'no.such.App'),
///       ));
/// }
/// ```
///
/// Uses plain asserts only — no `package:test` dependency in `lib/`.
/// Throws [ExamFailure] on the first violation.
library store_contracts.exam;

import 'store_contracts.dart';

class ExamFailure implements Exception {
  ExamFailure(this.message);
  final String message;
  @override
  String toString() => 'ExamFailure: $message';
}

Never _fail(String check, String detail) =>
    throw ExamFailure('$check: $detail');

/// Runs the full exam. See library docs for the fixture pattern.
Future<void> runContractExam(
  String name,
  StoreBackend Function() create, {
  required AppIdentity installTarget,
  required AppIdentity unknownTarget,
  AppIdentity? installedTarget,
}) async {
  final prefix = '[$name]';
  await _isAvailable('$prefix isAvailable', create);
  await _installReachesTerminal(
    '$prefix install→terminal',
    create,
    installTarget,
  );
  await _cancelFromActivePhase('$prefix cancel', create, installTarget);
  await _unknownIdIsTyped('$prefix unknown id', create, unknownTarget);
  if (installedTarget != null) {
    await _idempotentNoop(
      '$prefix idempotent install',
      create,
      installedTarget,
    );
  }
  await _recoverInFlight('$prefix recoverInFlight', create);
  await _listInstalled('$prefix listInstalled', create);
}

Future<void> _isAvailable(String check, StoreBackend Function() create) async {
  final backend = create();
  for (var i = 0; i < 2; i++) {
    final sw = Stopwatch()..start();
    await backend.isAvailable().timeout(
      const Duration(seconds: 5),
      onTimeout: () => _fail(check, 'isAvailable() did not complete within 5s'),
    );
    sw.stop();
    if (sw.elapsedMilliseconds > 200) {
      _fail(
        check,
        'isAvailable() took ${sw.elapsedMilliseconds}ms; contract requires <200ms',
      );
    }
  }
}

/// Drives install() to a terminal state, validating the DAG path,
/// progress monotonicity, terminal silence, and typed errors.
Future<List<OperationState>> _driveToTerminal(
  String check,
  StoreBackend Function() create,
  AppIdentity target, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final backend = create();
  late final OperationHandle handle;
  try {
    handle = await backend
        .install(target)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw ExamFailure(
            '$check: install() did not return a handle within 10s',
          ),
        );
  } on StoreException {
    // Backend refused via typed error — legal only for unknown/conflict.
    return [];
  }

  final seen = <OperationState>[handle.current];
  final sub = handle.state.listen(seen.add);
  try {
    final deadline = DateTime.now().add(timeout);
    while (!seen.last.isTerminal) {
      if (DateTime.now().isAfter(deadline)) {
        _fail(
          check,
          'no terminal state within ${timeout.inSeconds}s; '
          'stuck at ${seen.last.runtimeType}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Terminal silence: spec requires no events after terminal (500ms).
    final countAtTerminal = seen.length;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (seen.length != countAtTerminal) {
      _fail(
        check,
        'events emitted after terminal state ${seen.last.runtimeType}',
      );
    }
  } finally {
    await sub.cancel();
  }

  _assertLegalPath(check, seen);
  _assertProgressMonotonic(check, seen);
  final last = seen.last;
  if (last is Failed) _assertTypedError(check, last.error);
  return seen;
}

void _assertLegalPath(String check, List<OperationState> seen) {
  final first = seen.first;
  if (first is! Queued && first is! Restoring) {
    _fail(
      check,
      'first state was ${first.runtimeType}; '
      'must be Queued (or Restoring for re-attached handles)',
    );
  }
  for (var i = 1; i < seen.length; i++) {
    final prev = seen[i - 1];
    final next = seen[i];
    // The honest no-op: Queued → Done is legal only when nothing was done.
    final isHonestNoop = prev is Queued && next is Done && next.result.noop;
    if (isHonestNoop) continue;
    final allowed = legalTransitions[prev.runtimeType];
    if (allowed == null || !allowed.contains(next.runtimeType)) {
      _fail(
        check,
        'illegal transition ${prev.runtimeType} → ${next.runtimeType}; '
        'see operation-state-machine.md §2',
      );
    }
  }
}

void _assertProgressMonotonic(String check, List<OperationState> seen) {
  var bytes = -1;
  var fraction = -1.0;
  for (final s in seen) {
    if (s is Downloading) {
      if (s.bytesTotal != null && s.bytesDone > s.bytesTotal!) {
        _fail(check, 'bytesDone ${s.bytesDone} > bytesTotal ${s.bytesTotal}');
      }
      if (s.bytesDone < bytes) _fail(check, 'bytesDone decreased');
      bytes = s.bytesDone;
    } else if (s is Applying) {
      final f = s.fraction;
      if (f != null) {
        if (f < 0 || f > 1) _fail(check, 'fraction $f outside [0,1]');
        if (f < fraction) _fail(check, 'fraction decreased');
        fraction = f;
      }
    }
  }
}

void _assertTypedError(String check, StoreException error) {
  if (error.code.isEmpty) _fail(check, 'failed with empty error code');
  if (error.debugDetail.isEmpty) {
    _fail(check, 'failed with empty debugDetail (code=${error.code})');
  }
}

Future<void> _installReachesTerminal(
  String check,
  StoreBackend Function() create,
  AppIdentity target,
) async {
  final seen = await _driveToTerminal(check, create, target);
  if (seen.isEmpty) {
    _fail(
      check,
      'install() threw for the install target; '
      'expected a handle reaching a terminal state',
    );
  }
}

Future<void> _cancelFromActivePhase(
  String check,
  StoreBackend Function() create,
  AppIdentity target,
) async {
  final backend = create();
  final handle = await backend
      .install(target)
      .timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw ExamFailure('$check: install() hung'),
      );

  // Wait for a cancellable phase.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (handle.current is Queued ||
      handle.current is Restoring ||
      handle.current is Authenticating ||
      handle.current is Preparing) {
    if (DateTime.now().isAfter(deadline)) {
      _fail(
        check,
        'never reached a cancellable phase; '
        'stuck at ${handle.current.runtimeType}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (handle.current.isTerminal) {
    // Finished before we could cancel — legal, nothing to test.
    return;
  }

  final sw = Stopwatch()..start();
  await handle.cancel();
  final terminalDeadline = DateTime.now().add(const Duration(seconds: 15));
  while (!handle.current.isTerminal) {
    if (DateTime.now().isAfter(terminalDeadline)) {
      _fail(check, 'cancel() did not reach a terminal state within 15s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  sw.stop();
  final terminal = handle.current;
  if (terminal is! Cancelled && terminal is! Done) {
    _fail(
      check,
      'after cancel(), terminal was ${terminal.runtimeType}; must be Cancelled or Done',
    );
  }
  if (terminal is Failed) {
    _fail(
      check,
      'user cancel converted into Failed — forbidden by the contract',
    );
  }
  // Spec budget is 2s; the exam allows 5s slack for loaded machines.
  if (sw.elapsedMilliseconds > 5000) {
    _fail(
      check,
      'cancel() took ${sw.elapsedMilliseconds}ms to reach terminal; spec requires ≤2s',
    );
  }
}

Future<void> _unknownIdIsTyped(
  String check,
  StoreBackend Function() create,
  AppIdentity unknown,
) async {
  final backend = create();
  try {
    await backend
        .getDetails(unknown)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw ExamFailure('$check: getDetails() hung'),
        );
    _fail(check, 'getDetails(unknown id) did not throw');
  } on StoreException catch (e) {
    _assertTypedError(check, e);
  }
}

Future<void> _idempotentNoop(
  String check,
  StoreBackend Function() create,
  AppIdentity installed,
) async {
  final seen = await _driveToTerminal(check, create, installed);
  if (seen.isEmpty) return; // backend threw ConflictException — allowed.
  final last = seen.last;
  if (last is Done) {
    if (!last.result.noop) {
      _fail(
        check,
        'install on installed app completed without noop=true; '
        'expected idempotent no-op, no re-download',
      );
    }
    if (seen.any((s) => s is Downloading)) {
      _fail(check, 'install on installed app downloaded; noop must not fetch');
    }
  } else if (last is! Cancelled) {
    _fail(check, 'install on installed app ended in ${last.runtimeType}');
  }
}

Future<void> _recoverInFlight(
  String check,
  StoreBackend Function() create,
) async {
  final backend = create();
  final handles = await backend.recoverInFlight().timeout(
    const Duration(seconds: 10),
    onTimeout: () => throw ExamFailure('$check: recoverInFlight() hung'),
  );
  for (final h in handles) {
    if (h.current is! Restoring) {
      _fail(
        check,
        're-attached handle started at ${h.current.runtimeType}; must start with Restoring',
      );
    }
  }
}

/// Validates the additive listInstalled() contract: completes in time,
/// identities carry this backend's id, throws only StoreException
/// subtypes. Typed throws are legal; raw throws fail.
Future<void> _listInstalled(
  String check,
  StoreBackend Function() create,
) async {
  final backend = create();
  late final List<AppInfo> apps;
  try {
    apps = await backend.listInstalled().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw ExamFailure('$check: listInstalled() hung'),
    );
  } on StoreException catch (e) {
    _assertTypedError(check, e);
    return;
  } catch (e) {
    _fail(check, 'threw raw ${e.runtimeType}, not a StoreException');
  }
  for (final app in apps) {
    if (app.identity.backendId != backend.id) {
      _fail(
        check,
        'installed identity ${app.identity} carries backendId '
        '${app.identity.backendId} != ${backend.id}',
      );
    }
  }
}

/// Pins the additive default: a backend that does not override
/// listInstalled() must get [] — this is the LLD §10 guarantee that
/// keeps this change minor instead of major.
Future<void> runContractExamDefaultListInstalled(
  String name,
  StoreBackend Function() create,
) async {
  final backend = create();
  final apps = await backend.listInstalled();
  if (apps.isNotEmpty) {
    throw ExamFailure(
      '[$name] listInstalled default: expected [], got ${apps.length} apps; '
      'a backend that does not override listInstalled() must get the default',
    );
  }
}
