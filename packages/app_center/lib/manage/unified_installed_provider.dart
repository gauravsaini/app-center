/// Installed apps sourced from the unified store (StoreHost) for the
/// Manage page strangler-fig slice.
///
/// Reads [StoreHost.installed()], which fans out over every registered
/// backend and returns one [UnifiedApp] per installed app (v1 grouping:
/// no cross-backend merging). A backend failing degrades to partial
/// results — the host never throws — so this provider only errors if
/// something above the host breaks.
///
/// No `backend_*` import by design: this file sees only the host and
/// the contracts.
library;

import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// All apps the unified store reports as installed, for the Manage page
/// (`pages.manage.unified` flag on). Keep-alive: operations (remove)
/// outlive any single view of this list; callers invalidate after a
/// remove to refresh.
final unifiedInstalledProvider = FutureProvider<List<UnifiedApp>>(
  (ref) => ref.watch(storeHostProvider).installed(),
  name: 'unifiedInstalledProvider',
);
