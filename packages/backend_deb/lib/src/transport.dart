/// [PackageKitTransport]: everything the backend needs from PackageKit,
/// expressed in plain Dart. [RealPackageKitTransport] implements it over
/// raw D-Bus (the vendored `package:packagekit` client cannot parse the
/// 5-token IDs real daemons emit — deb-packageid-fix.md §1); tests script
/// [StubPackageKitTransport].
library;

/// Transport-level failure. The backend maps these to [StoreException];
/// they never escape the backend directly.
class PackageKitTransportException implements Exception {
  PackageKitTransportException(this.message);

  final String message;

  @override
  String toString() => 'packagekit: $message';
}

/// The requested package does not exist (cache or local).
class PackageKitNotFoundException extends PackageKitTransportException {
  PackageKitNotFoundException(super.message);
}

/// Transport-level deb package snapshot.
class DebPackageData {
  const DebPackageData({
    required this.name,
    required this.summary,
    required this.description,
    required this.version,
    this.installedVersion,
  });

  final String name;
  final String summary;
  final String description;
  final String version;
  final String? installedVersion;
}

/// Coarse transaction phase, in plain Dart.
enum DebTxStatus {
  unknown,
  download,
  install,
  remove,
  update,
  verifying,
  other,
}

/// How a PackageKit transaction ended.
enum DebTxOutcome { success, cancelled, failed }

/// Base of the transport-level transaction event stream.
sealed class DebTxEvent {
  const DebTxEvent();
}

/// Progress signal. [percentage] is 0..100 as reported by PackageKit.
final class DebTxProgress extends DebTxEvent {
  const DebTxProgress({required this.status, required this.percentage});

  final DebTxStatus status;
  final int percentage;
}

/// Terminal event. [errorCode] carries the raw PackageKit error name
/// (e.g. `packageNotFound`) so the backend can map typed errors.
final class DebTxDone extends DebTxEvent {
  const DebTxDone({
    required this.outcome,
    this.errorCode = '',
    this.errorDetails = '',
  });

  final DebTxOutcome outcome;
  final String errorCode;
  final String errorDetails;
}

/// A live PackageKit transaction, transport-side.
class DebTransaction {
  DebTransaction({
    required this.events,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  /// Progress events, then exactly one [DebTxDone].
  final Stream<DebTxEvent> events;
  final Future<void> Function() _cancel;

  /// Best effort: the event stream resolves the honest outcome.
  Future<void> cancel() => _cancel();
}

abstract class PackageKitTransport {
  /// Throw [PackageKitTransportException] when the daemon is unreachable.
  Future<void> checkAvailable();

  Future<List<DebPackageData>> search(String query);

  /// Throw [PackageKitNotFoundException] for unknown packages.
  Future<DebPackageData> getDetails(String name);

  Future<List<String>> installedNames();

  /// Bulk installed snapshot: name/version/summary from one
  /// `GetPackages(installed)` transaction plus descriptions from one
  /// `GetDetails` batch, deduped by name (multi-arch events share a
  /// name). Throw [PackageKitTransportException] when the batch fails;
  /// the backend falls back to the per-package path.
  Future<List<DebPackageData>> installedPackages();

  /// Packages with updates available.
  Future<List<DebPackageData>> updatesAvailable();

  /// Starts the install; the returned transaction's event stream
  /// drives the operation handle.
  Future<DebTransaction> install(String name);

  Future<DebTransaction> remove(String name);

  Future<DebTransaction> update(String name);
}
