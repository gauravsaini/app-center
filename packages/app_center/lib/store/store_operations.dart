/// Riverpod access to the host's [OperationEngine] surface.
///
/// This file sees only the host — never `backend_*`.
/// UI widgets consume these providers to enqueue operations, watch
/// in-flight work, and read pre-install permissions (ADR-009).
library;

import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';

/// All currently in-flight host operations (install/remove/update).
///
/// The host dedups one active operation per [AppIdentity] and emits the
/// snapshot + live updates; widgets match their app's handle out of the
/// list. Never auto-disposed: operations outlive any single card.
final activeOperationsProvider = StreamProvider<List<OperationHandle>>(
  (ref) => ref.watch(storeHostProvider).activeOperations(),
  name: 'activeOperationsProvider',
);

/// Details for one unified app — notably the pre-install [Permission]s.
///
/// Fetched lazily per install button so the search path never pays for
/// details. ADR-009: permissions are visible BEFORE the install action
/// is enabled.
final unifiedAppDetailsProvider =
    FutureProvider.family<AppDetails, AppIdentity>(
      (ref, id) => ref.watch(storeHostProvider).getDetails(id),
      name: 'unifiedAppDetailsProvider',
    );

/// Community-curated metadata for one canonical app
/// (docs/architecture/phase3-slice5.md §3).
///
/// Null unless the identity + metadata flags are on and the host has a
/// verified entry for `id` — the flag is the switch (the host returns
/// null before touching the cache when the flag is off), so the UI
/// never sees unverified metadata. Never throws (worst case: null).
final communityMetadataProvider =
    FutureProvider.family<CommunityAppMetadata?, CanonicalAppId>(
      (ref, id) => ref.watch(storeHostProvider).getCommunityMetadata(id),
      name: 'communityMetadataProvider',
    );
