/// Installed apps sourced from the unified store (StoreHost) for the
/// Manage page strangler-fig slice, plus the filter/sort state for the
/// unified Manage page polish.
///
/// Reads [StoreHost.installed()], which fans out over every registered
/// backend and returns one [UnifiedApp] per installed app (v1 grouping:
/// no cross-backend merging). A backend failing degrades to partial
/// results — the host never throws — so this provider only errors if
/// something above the host breaks.
///
/// Filtering and sorting are client-side over the fetched list (installed
/// sets are tens of items; no backend query needed) in
/// [unifiedManageVisibleAppsProvider], a pure function of the installed
/// list + the filter/sort [StateProvider]s. The filter state is page-scoped
/// and survives refetch.
///
/// No `backend_*` import by design: this file sees only the host and
/// the contracts.
library;

import 'package:app_center/l10n.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:store_host/store_host.dart';

/// All apps the unified store reports as installed, for the Manage page
/// (`pages.manage.unified` flag on).
///
/// Keep-alive: stale-while-revalidate. The old list stays visible while a
/// refetch is in flight (pull-to-refresh / operation completion), so the
/// page shows a slim progress indicator instead of a full-page spinner.
final unifiedInstalledProvider = FutureProvider<List<UnifiedApp>>((ref) {
  ref.keepAlive();
  return ref.watch(storeHostProvider).installed();
}, name: 'unifiedInstalledProvider');

/// Free-text search over installed app names (case-insensitive substring).
/// Written by the toolbar's debounced search field; read by
/// [unifiedManageVisibleAppsProvider].
final unifiedManageSearchProvider = StateProvider<String>(
  (_) => '',
  name: 'unifiedManageSearchProvider',
);

/// Package-source filter for the unified Manage page. [all] disables the
/// filter; every other value maps 1:1 to a contract [AppSource].
enum UnifiedManageSourceFilter { all, snap, deb, flatpak, appImage }

/// Typed mapping between [UnifiedManageSourceFilter] and [AppSource].
extension UnifiedManageSourceFilterX on UnifiedManageSourceFilter {
  /// The contract source this filter matches; `null` for [all].
  AppSource? get appSource => switch (this) {
    UnifiedManageSourceFilter.all => null,
    UnifiedManageSourceFilter.snap => AppSource.snap,
    UnifiedManageSourceFilter.deb => AppSource.deb,
    UnifiedManageSourceFilter.flatpak => AppSource.flatpak,
    UnifiedManageSourceFilter.appImage => AppSource.appImage,
  };

  /// Inverse mapping for building the chip row from the installed list.
  /// Returns `null` for sources with no chip ([AppSource.unknown]).
  static UnifiedManageSourceFilter? fromAppSource(AppSource source) =>
      switch (source) {
        AppSource.snap => UnifiedManageSourceFilter.snap,
        AppSource.deb => UnifiedManageSourceFilter.deb,
        AppSource.flatpak => UnifiedManageSourceFilter.flatpak,
        AppSource.appImage => UnifiedManageSourceFilter.appImage,
        AppSource.unknown => null,
      };
}

final unifiedManageSourceFilterProvider =
    StateProvider<UnifiedManageSourceFilter>(
      (_) => UnifiedManageSourceFilter.all,
      name: 'unifiedManageSourceFilterProvider',
    );

/// Sort orders the unified Manage page supports. Name only: the unified
/// contract carries no install size or install date, so size/date sorts
/// are deliberately omitted (see the HLD).
enum UnifiedManageSort { nameAsc, nameDesc }

extension UnifiedManageSortX on UnifiedManageSort {
  String localize(AppLocalizations l10n) => switch (this) {
    UnifiedManageSort.nameAsc => l10n.unifiedManageSortNameAsc,
    UnifiedManageSort.nameDesc => l10n.unifiedManageSortNameDesc,
  };
}

final unifiedManageSortProvider = StateProvider<UnifiedManageSort>(
  (_) => UnifiedManageSort.nameAsc,
  name: 'unifiedManageSortProvider',
);

/// Filtered + sorted view of [unifiedInstalledProvider].
///
/// Pure function of the installed list and the filter/sort state —
/// trivially testable without widgets.
final unifiedManageVisibleAppsProvider = Provider<List<UnifiedApp>>((ref) {
  final apps = ref.watch(unifiedInstalledProvider).valueOrNull ?? [];
  final q = ref.watch(unifiedManageSearchProvider).trim().toLowerCase();
  final src = ref.watch(unifiedManageSourceFilterProvider);
  final sort = ref.watch(unifiedManageSortProvider);
  final out = apps.where(
    (a) =>
        (q.isEmpty || a.preferred.name.toLowerCase().contains(q)) &&
        (src == UnifiedManageSourceFilter.all ||
            a.preferred.source == src.appSource),
  );
  final list = out.toList()
    ..sort(
      (x, y) => x.preferred.name.toLowerCase().compareTo(
        y.preferred.name.toLowerCase(),
      ),
    );
  return sort == UnifiedManageSort.nameAsc ? list : list.reversed.toList();
}, name: 'unifiedManageVisibleAppsProvider');

/// Debounce between an operation reaching a terminal state and the
/// installed-list refetch. A provider (not a const) so tests can override
/// it instead of waiting out the real delay.
final unifiedManageRefreshDebounceProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 500),
  name: 'unifiedManageRefreshDebounceProvider',
);
