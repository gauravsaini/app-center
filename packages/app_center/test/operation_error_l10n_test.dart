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

  /// One exception per taxonomy code, pinned to its l10n key. Each
  /// carries a distinctive debug-only marker that must never appear in
  /// the UI string.
  List<(StoreException, String Function(AppLocalizations))> mapping() => [
    (
      const NetworkException(debugDetail: 'net-debug-marker'),
      (l) => l.operationFailureNetwork,
    ),
    (
      const AuthException(debugDetail: 'auth-denied-debug-marker'),
      (l) => l.operationFailureAuthDenied,
    ),
    (
      const AuthException(
        debugDetail: 'auth-dismissed-debug-marker',
        kind: AuthKind.dismissed,
      ),
      (l) => l.operationFailureAuthDismissed,
    ),
    (
      const AuthException(
        debugDetail: 'auth-expired-debug-marker',
        kind: AuthKind.expired,
      ),
      (l) => l.operationFailureAuthExpired,
    ),
    (
      const DiskSpaceException(
        debugDetail: 'disk-debug-marker',
        neededBytes: 1,
        availableBytes: 0,
      ),
      (l) => l.operationFailureDiskFull,
    ),
    (
      const DependencyException(debugDetail: 'dep-debug-marker'),
      (l) => l.operationFailureDependency,
    ),
    (
      const VerificationException(debugDetail: 'verify-debug-marker'),
      (l) => l.operationFailureVerification,
    ),
    (
      const BackendUnavailableException(debugDetail: 'backend-debug-marker'),
      (l) => l.operationFailureBackendUnavailable,
    ),
    (
      const PermissionException(
        debugDetail: 'confinement-debug-marker',
        neededAccess: 'y',
      ),
      (l) => l.operationFailureConfinement,
    ),
    (
      const AppNotFoundException(debugDetail: 'notfound-debug-marker'),
      (l) => l.operationFailureNotFound,
    ),
    (
      const ConflictException(debugDetail: 'conflict-debug-marker'),
      (l) => l.operationFailureConflict,
    ),
    (
      const InterruptedException(debugDetail: 'interrupted-debug-marker'),
      (l) => l.operationFailureInterrupted,
    ),
    (
      const TimeoutException(
        debugDetail: 'timeout-debug-marker',
        stalledPhase: 'Applying',
      ),
      (l) => l.operationFailureTimeout,
    ),
    (
      const UnknownStoreException(
        debugDetail: 'unknown-debug-marker',
        rawOutput: 'raw-output-marker',
      ),
      (l) => l.operationFailureUnknown,
    ),
  ];

  Future<AppLocalizations> pumpL10n(WidgetTester tester) async {
    await tester.pumpApp((_) => const SizedBox());
    return tester.l10n;
  }

  testWidgets('codes map to their exact non-empty l10n keys', (tester) async {
    final l10n = await pumpL10n(tester);
    for (final (e, getter) in mapping()) {
      final reason = operationFailureReason(e, l10n);
      expect(reason, isNotEmpty, reason: 'code ${e.code} empty');
      expect(reason, getter(l10n), reason: 'code ${e.code}');
    }
  });

  testWidgets('debugDetail and rawOutput never appear in any output', (
    tester,
  ) async {
    final l10n = await pumpL10n(tester);
    for (final (e, _) in mapping()) {
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
