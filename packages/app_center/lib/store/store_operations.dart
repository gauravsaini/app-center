/// Riverpod access to the host's [OperationEngine] surface.
///
/// This file sees only the host and the contracts — never `backend_*`.
/// UI widgets consume these providers to enqueue operations, watch
/// in-flight work, and read pre-install permissions (ADR-009).
library;

import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_contracts/store_contracts.dart';
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
