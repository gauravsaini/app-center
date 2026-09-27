/// [InstalledResult]: the detailed outcome of
/// [StoreHost.installedDetailed].
///
/// A hung or throwing backend degrades to *partial* results instead of
/// failing the whole installed listing
/// (docs/architecture/parallel-installed.md §1): [apps] holds what the
/// healthy backends reported, and [partialBackendIds] names the
/// backends that were excluded this tick (hung past the
/// `installed.backend_timeout_ms` budget, or threw). The next listing
/// retries every enabled backend, hung one included — a backend that
/// recovers reappears with no retry list to maintain.
library;

import 'package:store_contracts/store_contracts.dart';

/// Detailed result of a unified installed listing.
class InstalledResult {
  const InstalledResult({required this.apps, required this.partialBackendIds});

  /// One [UnifiedApp] per reported [AppInfo] — no cross-backend merging
  /// (v1 grouping policy, same as search()). In backend registration
  /// order; completion order is nondeterministic and never leaks in.
  final List<UnifiedApp> apps;

  /// Ids of backends excluded this tick (hung or threw). Empty means
  /// every enabled backend answered.
  final List<String> partialBackendIds;

  /// True when at least one backend was excluded this tick.
  bool get isPartial => partialBackendIds.isNotEmpty;
}
