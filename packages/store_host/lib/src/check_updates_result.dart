/// [CheckUpdatesResult]: the detailed outcome of
/// [StoreHost.checkUpdatesDetailed].
///
/// A hung or throwing backend degrades to *partial* results instead of
/// failing the whole check (docs/architecture/parallel-check-updates.md
/// §1): [updates] holds what the healthy backends reported, and
/// [partialBackendIds] names the backends that were excluded this tick
/// (hung past the `updates.backend_timeout_ms` budget, or threw). The
/// next check retries every enabled backend, hung one included — a
/// backend that recovers reappears with no retry list to maintain.
library;

import 'package:store_contracts/store_contracts.dart';

/// Detailed result of a unified update check.
class CheckUpdatesResult {
  const CheckUpdatesResult({
    required this.updates,
    required this.partialBackendIds,
  });

  /// What the backends reported, in backend registration order —
  /// completion order is nondeterministic and never leaks in.
  final List<UpdateInfo> updates;

  /// Ids of backends excluded this tick (hung or threw). Empty means
  /// every enabled backend answered.
  final List<String> partialBackendIds;

  /// True when at least one backend was excluded this tick.
  bool get isPartial => partialBackendIds.isNotEmpty;
}
