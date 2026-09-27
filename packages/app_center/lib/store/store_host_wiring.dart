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

import 'package:backend_deb/backend_deb.dart';
import 'package:backend_flatpak/backend_flatpak.dart';
import 'package:backend_snap/backend_snap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// App-wide feature flags for the unified store.
///
/// Kill switches: `backend.<id>.enabled` (`snap`, `flatpak`, `deb`).
/// Defaults live in [MapFeatureFlags]; mutated via
/// [MapFeatureFlags.setFlag] — but only through this single shared
/// instance.
final storeFlagsProvider = Provider<FeatureFlags>(
  (_) => MapFeatureFlags(),
  name: 'storeFlagsProvider',
);

/// Builds the app-wide [StoreHost] with every backend registered.
///
/// The optional transports exist for tests: production always uses the
/// real transports (`PackageSnapdTransport`, `CliFlatpakTransport`,
/// `RealPackageKitTransport`). Backend availability is checked lazily
/// per query, never here.
StoreHost buildStoreHost(
  FeatureFlags flags, {
  SnapdTransport? snapTransport,
  FlatpakTransport? flatpakTransport,
  PackageKitTransport? debTransport,
}) {
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
  return host;
}

/// App-wide unified-store host. Single instance shared with
/// [storeFlagsProvider]; never auto-disposed.
final storeHostProvider = Provider<StoreHost>(
  (ref) => buildStoreHost(ref.watch(storeFlagsProvider)),
  name: 'storeHostProvider',
);
