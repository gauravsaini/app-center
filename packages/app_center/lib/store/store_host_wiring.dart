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
import 'package:backend_pacman/backend_pacman.dart';
import 'package:backend_rpm/backend_rpm.dart';
import 'package:backend_snap/backend_snap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// App-wide feature flags for the unified store.
///
/// Kill switches: `backend.<id>.enabled` (`snap`, `flatpak`, `deb`,
/// `appimage`, `rpm`, `pacman`).
/// Defaults live in [MapFeatureFlags]; mutated via
/// [MapFeatureFlags.setFlag] — but only through this single shared
/// instance.
final storeFlagsProvider = Provider<FeatureFlags>(
  (_) => MapFeatureFlags(),
  name: 'storeFlagsProvider',
);

/// Seeded kill switch for one backend id (`snap`, `flatpak`, `deb`,
/// `appimage`, `rpm`, `pacman`).
///
/// Sync flag read — nav visibility is a startup decision and must not
/// await probes (docs/architecture/platform-detection.md §6). The flag
/// reflects the detected platform's seeded default unless the user
/// overrode it via [MapFeatureFlags.setFlag].
final backendEnabledProvider = Provider.family<bool, String>(
  (ref, id) => ref.watch(storeFlagsProvider).isEnabled('backend.$id.enabled'),
  name: 'backendEnabledProvider',
);

/// Kill switch for the Phase 3 merged-card UI (`phase3.identity.enabled`).
///
/// The merged card (format picker on the details page, "N formats" chip on
/// the grid card) renders only when this is true AND the app carries a
/// canonical id — flag off or unresolved keeps today's per-backend UI bit
/// for bit. Follows the [backendEnabledProvider] pattern: a sync flag read,
/// no async probing.
final identityEnabledProvider = Provider<bool>(
  (ref) => ref.watch(storeFlagsProvider).isEnabled('phase3.identity.enabled'),
  name: 'identityEnabledProvider',
);

/// Kill switch for Phase 3 community app metadata
/// (docs/architecture/phase3-slice5.md §4).
///
/// True only when BOTH `phase3.identity.enabled` and
/// `phase3.metadata.enabled` are on — metadata keys off canonical ids,
/// so the identity flag gates everything: identity off means no
/// community metadata is ever shown, even with a verified file on
/// disk. Reads the identity flag through [identityEnabledProvider]
/// (not the flag map directly) so the settings toggle's invalidation
/// cascades here. The details page's community sections (description
/// override, community screenshots, curated permissions, rating)
/// render only when this is true AND the page's app carries a
/// canonical id AND the host returned a verified entry.
final metadataEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(identityEnabledProvider) &&
      ref.watch(storeFlagsProvider).isEnabled('phase3.metadata.enabled'),
  name: 'metadataEnabledProvider',
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
/// `RealPackageKitTransport`, `RealAppImageTransport`,
/// `RealRpmPackageKitTransport`, `CliPacmanTransport`).
/// Backend availability is checked lazily per query, never here.
StoreHost buildStoreHost(
  FeatureFlags flags, {
  SnapdTransport? snapTransport,
  FlatpakTransport? flatpakTransport,
  PackageKitTransport? debTransport,
  AppImageTransport? appimageTransport,
  RpmTransport? rpmTransport,
  PacmanTransport? pacmanTransport,
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
  host.registerBackend(
    BackendRpm(
      transport: rpmTransport ?? RealRpmPackageKitTransport(),
    ),
  );
  host.registerBackend(
    BackendPacman(
      transport: pacmanTransport ?? CliPacmanTransport(),
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
