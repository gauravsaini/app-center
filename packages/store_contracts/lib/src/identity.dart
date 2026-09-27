/// Normalized app identity and metadata. The host thinks in apps,
/// not packages (ADR-009): one [AppIdentity] per (backend, native id),
/// merged into [UnifiedApp] by the host.
library;

/// Globally unique app reference: backend id + the backend's own id.
///
/// Example: `AppIdentity(backendId: 'flatpak', nativeId: 'org.videolan.VLC')`.
class AppIdentity {
  const AppIdentity({required this.backendId, required this.nativeId});

  /// The [StoreBackend.id] that owns this app.
  final String backendId;

  /// The backend's own identifier for the app.
  final String nativeId;

  @override
  bool operator ==(Object other) =>
      other is AppIdentity &&
      other.backendId == backendId &&
      other.nativeId == nativeId;

  @override
  int get hashCode => Object.hash(backendId, nativeId);

  @override
  String toString() => '$backendId:$nativeId';
}

/// Which packaging format an app came from. Used for badges and the
/// format picker — never for ranking on its own.
enum AppSource { snap, deb, flatpak, appImage, rpm, pacman, unknown }

/// A sandbox permission, shown BEFORE install (ADR-009: trust is designed,
/// not documented). Empty list = backend cannot report permissions.
class Permission {
  const Permission({
    required this.id,
    required this.label,
    this.granted = true,
  });

  /// Stable id, e.g. 'network', 'home-read', 'camera'.
  final String id;

  /// Human-readable label. The host localizes; backends send English.
  final String label;

  final bool granted;
}

/// Search-result / listing-level app data. Never null-garbage:
/// unknown values stay null (`rating: null`, never `0.0`-as-unknown).
class AppInfo {
  const AppInfo({
    required this.identity,
    required this.name,
    required this.summary,
    required this.iconUrl,
    required this.source,
    this.version,
    this.installedVersion,
    this.installSizeBytes,
    this.rating,
    this.updateAvailable,
  });

  final AppIdentity identity;
  final String name;
  final String summary;

  /// Host-resolved/cached icon URL.
  final String iconUrl;
  final AppSource source;

  final String? version;

  /// Null = not installed.
  final String? installedVersion;
  final int? installSizeBytes;

  /// Null = no data (ADR-005: ratings degraded in Phase 0).
  final double? rating;
  final bool? updateAvailable;

  bool get isInstalled => installedVersion != null;
}

/// Full details for the app page.
class AppDetails {
  const AppDetails({
    required this.app,
    required this.description,
    this.screenshots = const [],
    this.permissions = const [],
    this.license,
    this.homepage,
  });

  final AppInfo app;
  final String description;
  final List<String> screenshots;
  final List<Permission> permissions;
  final String? license;
  final String? homepage;
}
