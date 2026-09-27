/// Available updates sourced from the unified store (StoreHost) for the
/// updates strangler-fig slice.
///
/// [unifiedUpdatesResultProvider] is the single fetch:
/// [StoreHost.checkUpdatesDetailed()] fans out over every registered
/// backend with a per-backend `updates.backend_timeout_ms` budget. A
/// backend that hangs or fails degrades to partial results — the host
/// never throws — so this provider only errors if something above the
/// host breaks. [unifiedUpdatesProvider] is a projection over it
/// (`.updates`), so badge, section, and scheduler all share one
/// in-flight fetch; watching the result provider's `.future` joins it
/// instead of double-fetching.
///
/// No `backend_*` import by design: this file sees only the host and
/// the contracts.
library;

import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// The full update-check result: updates plus which backends were
/// excluded this tick ([CheckUpdatesResult.partialBackendIds]). The
/// one shared fetch behind the updates surface (`pages.updates.unified`
/// flag on). Keep-alive: an update changes what this contains and the
/// result must outlive any single view while updates are in flight;
/// callers invalidate after an update to refresh.
final unifiedUpdatesResultProvider = FutureProvider<CheckUpdatesResult>(
  (ref) => ref.watch(storeHostProvider).checkUpdatesDetailed(),
  name: 'unifiedUpdatesResultProvider',
);

/// All available updates the unified store reports, for the updates
/// surface. A projection over [unifiedUpdatesResultProvider] — same
/// type and contract as before, no second fetch.
final unifiedUpdatesProvider = FutureProvider<List<UpdateInfo>>(
  (ref) async => (await ref.watch(unifiedUpdatesResultProvider.future)).updates,
  name: 'unifiedUpdatesProvider',
);
