/// `StoreException` → localized user-facing reason.
///
/// Keyed on [StoreException.code] — stable for telemetry + i18n per
/// operation-state-machine §7. Never keyed on message text (that is the
/// legacy `ErrorMessage` regex approach in `error_l10n.dart`, which stays
/// snapd-only and untouched). [StoreException.debugDetail] and
/// [UnknownStoreException.rawOutput] are never surfaced by this
/// function.
library;

import 'package:app_center/l10n.dart';
import 'package:store_host/store_host.dart';

/// Concise user-facing reason for a failed operation.
String operationFailureReason(StoreException e, AppLocalizations l10n) =>
    switch (e.code) {
      'network' => l10n.operationFailureNetwork,
      'auth_denied' => l10n.operationFailureAuthDenied,
      'auth_dismissed' => l10n.operationFailureAuthDismissed,
      'auth_expired' => l10n.operationFailureAuthExpired,
      'disk_full' => l10n.operationFailureDiskFull,
      'dependency' => l10n.operationFailureDependency,
      'verification' => l10n.operationFailureVerification,
      'backend_unavailable' => l10n.operationFailureBackendUnavailable,
      'confinement' => l10n.operationFailureConfinement,
      'not_found' => l10n.operationFailureNotFound,
      'conflict' => l10n.operationFailureConflict,
      'interrupted' => l10n.operationFailureInterrupted,
      'timeout' => l10n.operationFailureTimeout,
      _ => l10n.operationFailureUnknown,
    };
