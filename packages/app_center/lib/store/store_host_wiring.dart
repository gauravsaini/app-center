/// Composition root for the unified *nix store.
///
/// This is the ONLY file in `app_center` that may import `backend_*`
/// packages. UI pages import `store_host`/`store_contracts` only — the
/// dependency trace lever enforces this: `lib/store/` is host-layer, not
/// UI-layer, so backend imports here are the sanctioned composition
/// boundary, not a violation.
///
/// Nothing here is wired into `main()` yet. UI reaches the host through
/// [storeFlagsProvider] and [storeHostProvider]; both instances are built
/// once and shared (no auto-dispose) so the whole app sees one catalog,
/// one flag set, one operation engine.
library;

import 'package:backend_appimage/backend_appimage.dart';
import 'package:backend_deb/backend_deb.dart';
import 'package:backend_flatpak/backend_flatpak.dart';
import 'package:backend_snap/backend_snap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// App-wide feature flags for the unified store.
///
/// Kill switches: `backend.<id>.enabled` (`snap`, `flatpak`, `deb`,
/// `appimage`).
/// Defaults live in [MapFeatureFlags]; mutated via
/// [MapFeatureFlags.setFlag] — but only through this single shared
/// instance.
final storeFlagsProvider = Provider<FeatureFlags>(
  (_) => MapFeatureFlags(),
  name: 'storeFlagsProvider',
);

/// Seeded kill switch for one backend id (`snap`, `flatpak`, `deb`,
/// `appimage`).
///
/// Sync flag read — nav visibility is a startup decision and must not
/// await probes (docs/architecture/platform-detection.md §6). The flag
/// reflects the detected platform's seeded default unless the user
/// overrode it via [MapFeatureFlags.setFlag].
final backendEnabledProvider = Provider.family<bool, String>(
  (ref, id) => ref.watch(storeFlagsProvider).isEnabled('backend.$id.enabled'),
  name: 'backendEnabledProvider',
);

/// Builds the app-wide [StoreHost] with every backend registered.
///
/// Detect → seed → construct → register: [detectPlatform] runs first
/// (or [platformOverride] in tests), then [seedPlatformBackendDefaults]
/// writes the detected defaults into [flags] *before* any backend is
/// registered — no backend is ever registered against unseeded flags.
/// With a foreign [FeatureFlags] implementation the seed is skipped and
/// compiled defaults apply (unknown-platform behavior). Detection never
/// throws; the worst case is [PlatformInfo.unknown()].
///
/// The optional transports exist for tests: production always uses the
/// real transports (`PackageSnapdTransport`, `CliFlatpakTransport`,
/// `RealPackageKitTransport`, `RealAppImageTransport`).
/// Backend availability is checked lazily per query, never here.
StoreHost buildStoreHost(
  FeatureFlags flags, {
  SnapdTransport? snapTransport,
  FlatpakTransport? flatpakTransport,
  PackageKitTransport? debTransport,
  AppImageTransport? appimageTransport,
  // Test seams (docs/architecture/platform-detection.md §8): inject a
  // fake platform. Production always passes null and detection runs
  // against /etc/os-release.
  PlatformInfo? platformOverride,
  OsReleaseReader? osReleaseReader,
}) {
  final platform = platformOverride ?? detectPlatform(reader: osReleaseReader);
  if (flags is MapFeatureFlags) {
    seedPlatformBackendDefaults(flags, platform);
  }
  final host = StoreHost(flags: flags);
  host.registerBackend(
    BackendSnap(
      transport: snapTransport ?? PackageSnapdTransport(),
    ),
  );
  host.registerBackend(
    BackendFlatpak(
      transport: flatpakTransport ?? CliFlatpakTransport(),
    ),
  );
  host.registerBackend(
    BackendDeb(
      transport: debTransport ?? RealPackageKitTransport(),
    ),
  );
  host.registerBackend(
    BackendAppimage(
      transport: appimageTransport ?? RealAppImageTransport(),
    ),
  );
  return host;
}

/// App-wide unified-store host. Single instance shared with
/// [storeFlagsProvider]; never auto-disposed.
final storeHostProvider = Provider<StoreHost>(
  (ref) => buildStoreHost(ref.watch(storeFlagsProvider)),
  name: 'storeHostProvider',
);
