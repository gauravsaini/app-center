/// Unit tests for [operationFailureReason] — the first code-keyed
/// `StoreException` → l10n localizer (per-row-failure LLD §8).
///
/// Keyed on [StoreException.code], never on message text; `debugDetail`
/// and `rawOutput` must never leak into the localized output.
library;

import 'package:app_center/error/operation_error_l10n.dart';
import 'package:app_center/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

void main() {
  tearDown(resetAllServices);

  /// One exception per taxonomy code. Each carries a distinctive
  /// debug-only marker that must never appear in the UI string.
  List<StoreException> taxonomy() => const [
    NetworkException(debugDetail: 'net-debug-marker'),
    AuthException(debugDetail: 'auth-denied-debug-marker'),
    AuthException(
      debugDetail: 'auth-dismissed-debug-marker',
      kind: AuthKind.dismissed,
    ),
    AuthException(
      debugDetail: 'auth-expired-debug-marker',
      kind: AuthKind.expired,
    ),
    DiskSpaceException(
      debugDetail: 'disk-debug-marker',
      neededBytes: 100,
      availableBytes: 1,
    ),
    DependencyException(debugDetail: 'dep-debug-marker'),
    VerificationException(debugDetail: 'verify-debug-marker'),
    BackendUnavailableException(debugDetail: 'backend-debug-marker'),
    PermissionException(
      debugDetail: 'confinement-debug-marker',
      neededAccess: 'host flatpak',
    ),
    AppNotFoundException(debugDetail: 'notfound-debug-marker'),
    ConflictException(debugDetail: 'conflict-debug-marker'),
    InterruptedException(debugDetail: 'interrupted-debug-marker'),
    TimeoutException(
      debugDetail: 'timeout-debug-marker',
      stalledPhase: 'Applying',
    ),
    UnknownStoreException(
      debugDetail: 'unknown-debug-marker',
      rawOutput: 'raw-output-marker',
    ),
  ];

  /// Pinned code → l10n getter contract.
  List<(StoreException, String Function(AppLocalizations))> mapping() => [
    (
      const NetworkException(debugDetail: 'x'),
      (l) => l.operationFailureNetwork,
    ),
    (
      const AuthException(debugDetail: 'x'),
      (l) => l.operationFailureAuthDenied,
    ),
    (
      const AuthException(debugDetail: 'x', kind: AuthKind.dismissed),
      (l) => l.operationFailureAuthDismissed,
    ),
    (
      const AuthException(debugDetail: 'x', kind: AuthKind.expired),
      (l) => l.operationFailureAuthExpired,
    ),
    (
      const DiskSpaceException(
        debugDetail: 'x',
        neededBytes: 1,
        availableBytes: 0,
      ),
      (l) => l.operationFailureDiskFull,
    ),
    (
      const DependencyException(debugDetail: 'x'),
      (l) => l.operationFailureDependency,
    ),
    (
      const VerificationException(debugDetail: 'x'),
      (l) => l.operationFailureVerification,
    ),
    (
      const BackendUnavailableException(debugDetail: 'x'),
      (l) => l.operationFailureBackendUnavailable,
    ),
    (
      const PermissionException(
        debugDetail: 'x',
        neededAccess: 'y',
      ),
      (l) => l.operationFailureConfinement,
    ),
    (
      const AppNotFoundException(debugDetail: 'x'),
      (l) => l.operationFailureNotFound,
    ),
    (
      const ConflictException(debugDetail: 'x'),
      (l) => l.operationFailureConflict,
    ),
    (
      const InterruptedException(debugDetail: 'x'),
      (l) => l.operationFailureInterrupted,
    ),
    (
      const TimeoutException(debugDetail: 'x', stalledPhase: 'Applying'),
      (l) => l.operationFailureTimeout,
    ),
    (
      const UnknownStoreException(debugDetail: 'x'),
      (l) => l.operationFailureUnknown,
    ),
  ];

  Future<AppLocalizations> pumpL10n(WidgetTester tester) async {
    await tester.pumpApp((_) => const SizedBox());
    return tester.l10n;
  }

  testWidgets('every taxonomy code maps to a non-empty localized string', (
    tester,
  ) async {
    final l10n = await pumpL10n(tester);
    for (final e in taxonomy()) {
      final reason = operationFailureReason(e, l10n);
      expect(reason, isNotEmpty, reason: 'code ${e.code}');
    }
  });

  testWidgets('codes map to their exact l10n keys', (tester) async {
    final l10n = await pumpL10n(tester);
    for (final (e, getter) in mapping()) {
      expect(
        operationFailureReason(e, l10n),
        getter(l10n),
        reason: 'code ${e.code}',
      );
    }
  });

  testWidgets('an unrecognized code falls through to the unknown message', (
    tester,
  ) async {
    final l10n = await pumpL10n(tester);
    // 'unknown' is deliberately absent from the switch cases: the
    // catch-all exception exercises the `_` fall-through branch, the
    // same branch a future subtype with a new code would hit. (A
    // test-only StoreException subtype is impossible: the class is
    // sealed.)
    expect(
      operationFailureReason(
        const UnknownStoreException(debugDetail: 'weird'),
        l10n,
      ),
      l10n.operationFailureUnknown,
    );
  });

  testWidgets('debugDetail and rawOutput never appear in any output', (
    tester,
  ) async {
    final l10n = await pumpL10n(tester);
    for (final e in taxonomy()) {
      final reason = operationFailureReason(e, l10n);
      expect(
        reason,
        isNot(contains(e.debugDetail)),
        reason: 'code ${e.code} leaks debugDetail',
      );
      if (e is UnknownStoreException) {
        expect(
          reason,
          isNot(contains(e.rawOutput)),
          reason: 'rawOutput leaks into the UI string',
        );
      }
    }
    // The timeout reason deliberately omits stalledPhase (debug vocabulary).
    final timeout = operationFailureReason(
      const TimeoutException(debugDetail: 'x', stalledPhase: 'Applying'),
      l10n,
    );
    expect(timeout, isNot(contains('Applying')));
  });
}
