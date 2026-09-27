/// [RpmTransport]: everything the RPM backend needs from PackageKit,
/// expressed in plain Dart. [RealRpmPackageKitTransport] implements it
/// over raw D-Bus (`package:dbus`); tests script [StubRpmTransport]
/// (in `lib/testing.dart`).
///
/// Package-id parsing happens HERE, at the seam — never via
/// `package:packagekit`'s strict 4-token `PackageKitPackageId.fromString`,
/// which throws on the dnf5 backend's 5-token IDs (research D1). The EVR
/// is opaque end-to-end: carried verbatim, never split.
library;

/// Tolerant PackageKit package-id: `name;evr;arch;origin;data`.
/// The 5-token dnf5 wire shape. `evr` is opaque — carried verbatim,
/// never split (epoch 0 is omitted by the backend; research §1.2).
class RpmPackageId {
  const RpmPackageId({
    required this.name,
    required this.evr,
    required this.arch,
    required this.origin,
    required this.data,
  });

  final String name;

  /// Opaque epoch:version-release string. Never parsed or rebuilt.
  final String evr;
  final String arch;
  final String origin;

  /// 'installed' for installed packages, else ''.
  final String data;

  bool get isInstalled => data == 'installed';

  /// The UI card key: multi-arch packages are separate cards.
  String get cardKey => '$name.$arch';

  /// Throws [FormatException] unless exactly 5 tokens. Never invents
  /// missing fields; never touches the EVR.
  factory RpmPackageId.parse(String raw) {
    final t = raw.split(';');
    if (t.length != 5 || t[0].isEmpty || t[2].isEmpty) {
      throw FormatException('not a 5-token rpm package id: $raw');
    }
    return RpmPackageId(
      name: t[0],
      evr: t[1],
      arch: t[2],
      origin: t[3],
      data: t[4],
    );
  }

  /// Verbatim round-trip: what the daemon emitted is what we send back.
  @override
  String toString() => '$name;$evr;$arch;$origin;$data';
}

/// Transport-level failure. The backend maps these to [StoreException]
/// subtypes; they never escape the backend directly.
class RpmTransportException implements Exception {
  RpmTransportException(this.message);

  final String message;

  @override
  String toString() => 'rpm packagekit: $message';
}

/// The requested package does not exist.
class RpmNotFoundException extends RpmTransportException {
  RpmNotFoundException(super.message);
}

/// Transport-level rpm package snapshot.
class RpmPackageData {
  const RpmPackageData({
    required this.id,
    required this.name,
    required this.arch,
    required this.evr,
    required this.summary,
    this.description = '',
    this.license = '',
    this.homepage = '',
    this.installSize = 0,
    this.installed = false,
    this.installedEvr,
  });

  /// Verbatim package-id (the backend's nativeId).
  final String id;
  final String name;
  final String arch;

  /// Opaque; display only.
  final String evr;
  final String summary;
  final String description;
  final String license;
  final String homepage;

  /// Install size in bytes, from the Details `size` field.
  final int installSize;
  final bool installed;

  /// Set on update entries: the installed EVR (fromVersion).
  final String? installedEvr;
}

/// Coarse transaction phase, in plain Dart (mirrors deb).
///
/// `waitingForAuth` is the polkit-prompt phase (PackageKit
/// `waitingForAuth`): install/remove transactions hit it on stock
/// Fedora while the auth dialog is in flight (research §6, LLD §8).
enum RpmTxStatus {
  unknown,
  download,
  install,
  remove,
  update,
  verifying,
  waitingForAuth,
  other,
}

/// How a PackageKit transaction ended.
enum RpmTxOutcome { success, cancelled, failed }

/// Base of the transport-level transaction event stream.
sealed class RpmTxEvent {
  const RpmTxEvent();
}

/// Progress signal. [percentage] is 0..100 as reported by PackageKit.
final class RpmTxProgress extends RpmTxEvent {
  const RpmTxProgress({required this.status, required this.percentage});

  final RpmTxStatus status;
  final int percentage;
}

/// Terminal event. [errorCode] carries the raw PackageKit error name
/// (e.g. `packageNotFound`) so the backend can map typed errors.
final class RpmTxDone extends RpmTxEvent {
  const RpmTxDone({
    required this.outcome,
    this.errorCode = '',
    this.errorDetails = '',
  });

  final RpmTxOutcome outcome;
  final String errorCode;
  final String errorDetails;
}

/// A live PackageKit transaction, transport-side.
class RpmTransaction {
  RpmTransaction({
    required this.events,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  /// Progress events, then exactly one [RpmTxDone].
  final Stream<RpmTxEvent> events;
  final Future<void> Function() _cancel;

  /// Best effort: the event stream resolves the honest outcome.
  Future<void> cancel() => _cancel();
}

abstract class RpmTransport {
  /// Throw [RpmTransportException] when the daemon is unreachable.
  Future<void> checkAvailable();

  /// One SearchNames transaction with the arch filter
  /// (native arch + noarch). Returns one entry per (name, arch).
  Future<List<RpmPackageData>> search(String query);

  /// Resolve (name, arch) fresh, then one GetDetails transaction.
  /// Throw [RpmNotFoundException] for unknown packages.
  Future<RpmPackageData> getDetails(String packageId);

  /// Verbatim package-ids of installed packages (legacy path).
  Future<List<String>> installedIds();

  /// Bulk installed snapshot: GetPackages({installed}) + one batched
  /// GetDetails, deduped by (name, arch). Throw
  /// [RpmTransportException] when the batch fails; the backend falls
  /// back to the per-package path.
  Future<List<RpmPackageData>> installedPackages();

  /// One GetUpdates transaction. Each entry's [RpmPackageData.id] is
  /// the *update* package-id; [RpmPackageData.installedEvr] carries the
  /// installed EVR for fromVersion.
  Future<List<RpmPackageData>> updatesAvailable();

  /// Starts the install; the returned transaction's event stream
  /// drives the operation handle. Re-resolves (name, arch) at mutate
  /// time (origin shifts between query and transaction).
  Future<RpmTransaction> install(String packageId);

  Future<RpmTransaction> remove(String packageId);

  Future<RpmTransaction> update(String packageId);
}
