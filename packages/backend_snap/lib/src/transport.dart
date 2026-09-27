/// [SnapdTransport]: everything the backend needs from snapd, expressed
/// in plain Dart snapshots. [PackageSnapdTransport] implements it over
/// `package:snapd`; tests script [StubSnapdTransport].
library;

import 'dart:async';

/// Transport-level failure. The backend maps these to [StoreException];
/// they never escape the backend directly.
class SnapdTransportException implements Exception {
  SnapdTransportException(this.message);

  final String message;

  @override
  String toString() => 'snapd: $message';
}

/// The requested snap does not exist (store or local).
class SnapdNotFoundException extends SnapdTransportException {
  SnapdNotFoundException(super.message);
}

/// One task inside a snapd change.
class SnapdTaskSnapshot {
  const SnapdTaskSnapshot({
    required this.kind,
    required this.status,
    required this.done,
    required this.total,
  });

  /// e.g. `download-snap`, `validate-snap`, `link-snap`.
  final String kind;

  /// e.g. `Do`, `Doing`, `Done`.
  final String status;
  final int done;
  final int total;
}

/// Transport-level snapshot of a snapd change.
class SnapdChangeSnapshot {
  const SnapdChangeSnapshot({
    required this.id,
    required this.kind,
    required this.status,
    required this.ready,
    required this.error,
    required this.snapNames,
    required this.tasks,
  });

  final String id;

  /// e.g. `install`, `refresh`, `remove`.
  final String kind;

  /// `Do`, `Doing`, `Done`, `Error`, `Hold`, ...
  final String status;
  final bool ready;
  final String error;
  final List<String> snapNames;
  final List<SnapdTaskSnapshot> tasks;
}

/// Transport-level snap summary (store or local).
class SnapSummaryData {
  const SnapSummaryData({
    required this.name,
    required this.title,
    required this.summary,
    required this.description,
    required this.version,
    required this.iconUrl,
    required this.confinement,
    this.installedVersion,
  });

  final String name;
  final String title;
  final String summary;
  final String description;
  final String version;
  final String iconUrl;

  /// `strict`, `classic`, `devmode`.
  final String confinement;
  final String? installedVersion;
}

abstract class SnapdTransport {
  /// Throw [SnapdTransportException] when snapd is not reachable.
  Future<void> checkAvailable();

  Future<List<SnapSummaryData>> find(String query);

  /// Throw [SnapdNotFoundException] for unknown snaps.
  Future<SnapSummaryData> getDetails(String name);

  Future<List<String>> installedNames();

  /// All installed snaps in one bulk call. Throw
  /// [SnapdTransportException] when snapd is not reachable.
  Future<List<SnapSummaryData>> installedSnaps();

  /// Snaps with updates available in the store.
  Future<List<SnapSummaryData>> updatesAvailable();

  /// Returns the change id.
  Future<String> install(String name, {required bool classic});

  /// Returns the change id.
  Future<String> remove(String name);

  /// Returns the change id.
  Future<String> refresh(String name);

  Future<SnapdChangeSnapshot> getChange(String id);

  Future<List<SnapdChangeSnapshot>> inProgressChanges();

  /// Best effort: swallowing "already done" failures is the caller's job.
  Future<void> abortChange(String id);
}
