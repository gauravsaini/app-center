/// Available updates sourced from the unified store (StoreHost) for the
/// updates strangler-fig slice.
///
/// Reads [StoreHost.checkUpdates()], which fans out over every
/// registered backend and returns one [UpdateInfo] per available
/// update. A backend failing degrades to partial results — the host
/// never throws — so this provider only errors if something above the
/// host breaks.
///
/// No `backend_*` import by design: this file sees only the host and
/// the contracts.
library;

import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// All available updates the unified store reports, for the updates
/// surface (`pages.updates.unified` flag on). Keep-alive: an update
/// changes what this list contains and the list must outlive any
/// single view while updates are in flight; callers invalidate after
/// an update to refresh.
final unifiedUpdatesProvider = FutureProvider<List<UpdateInfo>>(
  (ref) => ref.watch(storeHostProvider).checkUpdates(),
  name: 'unifiedUpdatesProvider',
);
