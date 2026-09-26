/// Typed error taxonomy. Every backend maps its native errors into this
/// hierarchy; `failed` states carry these and the host renders localized
/// messages + affordances from [Remediation]. Telemetry counts by [code],
/// never by message text.
library;

/// Structured next step — not a string. The host maps each to an action:
/// retry → Retry button, freeSpace → open disk settings, fixBackend →
/// backend troubleshooting, reportBug → prefilled bug report, none →
/// quiet note.
enum Remediation { retry, freeSpace, checkNetwork, fixBackend, reportBug, none }

sealed class StoreException implements Exception {
  const StoreException();

  /// Stable code for telemetry + i18n, e.g. 'network', 'disk_full'.
  String get code;

  /// Developer English. Logs only — never shown raw to users.
  String get debugDetail;

  /// Structured next step.
  Remediation get remediation;

  /// Which backend raised it, if known.
  String? get backendId => null;

  bool get retryable => remediation == Remediation.retry;
}

/// Offline, timeout, DNS, unreachable mirror.
final class NetworkException extends StoreException {
  const NetworkException({required this.debugDetail, this.attemptedHost, this.backendId});

  @override
  final String debugDetail;
  final String? attemptedHost;
  @override
  final String? backendId;

  @override
  String get code => 'network';
  @override
  Remediation get remediation => Remediation.retry;
}

/// User denied / dismissed the privilege prompt, or auth expired.
final class AuthException extends StoreException {
  const AuthException({required this.debugDetail, this.kind = AuthKind.denied, this.backendId});

  @override
  final String debugDetail;
  final AuthKind kind;
  @override
  final String? backendId;

  @override
  String get code => switch (kind) {
        AuthKind.denied => 'auth_denied',
        AuthKind.dismissed => 'auth_dismissed',
        AuthKind.expired => 'auth_expired',
      };
  // Never nag the user for saying no.
  @override
  Remediation get remediation => Remediation.none;
}

enum AuthKind { denied, dismissed, expired }

/// Not enough disk space. Carries numbers so the UI can say how much.
final class DiskSpaceException extends StoreException {
  const DiskSpaceException(
      {required this.debugDetail, required this.neededBytes, required this.availableBytes, this.backendId});

  @override
  final String debugDetail;
  final int neededBytes;
  final int availableBytes;
  @override
  final String? backendId;

  @override
  String get code => 'disk_full';
  @override
  Remediation get remediation => Remediation.freeSpace;
}

/// Unmet dependencies / broken packages.
final class DependencyException extends StoreException {
  const DependencyException({required this.debugDetail, this.details = const [], this.backendId});

  @override
  final String debugDetail;
  final List<String> details;
  @override
  final String? backendId;

  @override
  String get code => 'dependency';
  @override
  Remediation get remediation => Remediation.none;
}

/// Checksum / signature mismatch.
final class VerificationException extends StoreException {
  const VerificationException({required this.debugDetail, this.expected, this.actual, this.backendId});

  @override
  final String debugDetail;
  final String? expected;
  final String? actual;
  @override
  final String? backendId;

  @override
  String get code => 'verification';
  @override
  Remediation get remediation => Remediation.retry;
}

/// Backend died mid-operation or isn't installed.
final class BackendUnavailableException extends StoreException {
  const BackendUnavailableException({required this.debugDetail, this.backendId});

  @override
  final String debugDetail;
  @override
  final String? backendId;

  @override
  String get code => 'backend_unavailable';
  @override
  Remediation get remediation => Remediation.fixBackend;
}

/// The vehicle/confinement can't reach the backend (our snap/flatpak story).
final class PermissionException extends StoreException {
  const PermissionException({required this.debugDetail, required this.neededAccess, this.backendId});

  @override
  final String debugDetail;

  /// Human-readable description of the access needed, e.g.
  /// 'host flatpak via flatpak-spawn'.
  final String neededAccess;
  @override
  final String? backendId;

  @override
  String get code => 'confinement';
  @override
  Remediation get remediation => Remediation.fixBackend;
}

/// The app vanished from the index mid-operation.
final class AppNotFoundException extends StoreException {
  const AppNotFoundException({required this.debugDetail, this.backendId});

  @override
  final String debugDetail;
  @override
  final String? backendId;

  @override
  String get code => 'not_found';
  @override
  Remediation get remediation => Remediation.none;
}

/// Already in the desired state. Backends should prefer idempotent
/// `done(noop: true)` over this, but may return it when the no-op
/// can't be detected cheaply.
final class ConflictException extends StoreException {
  const ConflictException({required this.debugDetail, this.backendId});

  @override
  final String debugDetail;
  @override
  final String? backendId;

  @override
  String get code => 'conflict';
  @override
  Remediation get remediation => Remediation.none;
}

/// App restarted / system shut down mid-operation.
final class InterruptedException extends StoreException {
  const InterruptedException({required this.debugDetail, this.backendId});

  @override
  final String debugDetail;
  @override
  final String? backendId;

  @override
  String get code => 'interrupted';
  @override
  Remediation get remediation => Remediation.retry;
}

/// Stall watchdog fired: no progress events for too long.
final class TimeoutException extends StoreException {
  const TimeoutException({required this.debugDetail, this.stalledPhase, this.backendId});

  @override
  final String debugDetail;
  final String stalledPhase;
  @override
  final String? backendId;

  @override
  String get code => 'timeout';
  @override
  Remediation get remediation => Remediation.retry;
}

/// Catch-all. A bug-report generator, not a user message.
/// [rawOutput] goes to the bug report, never to the UI.
final class UnknownStoreException extends StoreException {
  const UnknownStoreException({required this.debugDetail, this.rawOutput, this.backendId});

  @override
  final String debugDetail;
  final String? rawOutput;
  @override
  final String? backendId;

  @override
  String get code => 'unknown';
  @override
  Remediation get remediation => Remediation.reportBug;
}
