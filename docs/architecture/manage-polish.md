# Manage Polish HLD/LLD — filters, sort, auto-refresh

Parent: [manage-strangle-hld.md](manage-strangle-hld.md). Closes the recorded
honest gap: "unified Manage MVP (no filters/sort/auto-refresh)".

## HLD

### 1. Goal

`UnifiedManagePage` (behind `pages.manage.unified`, default off) gains the
three affordances users expect from the legacy Manage page, without faking
anything the backends don't provide:

- **Filter**: free-text search (name) + package-source chips.
- **Sort**: name A→Z / Z→A only — the only ordering the data supports.
- **Refresh**: pull-to-refresh + automatic list refresh when an
  install/remove/update operation reaches a terminal state.

### 2. Non-goals

- Cross-backend deduplication ("one app, one card" is Phase 3).
- Sort by install size / install date — **deliberately omitted** (see §4).
- Timer-based polling — refresh is event-driven only (operation terminal),
  not on a clock.

### 3. Filter taxonomy

| Filter | Source of truth | Notes |
|---|---|---|
| Text search | `UnifiedApp.preferred.name` substring, case-insensitive | Debounced 200ms (reuse `_DebouncedSearchField` pattern from legacy `manage_page.dart`) |
| Source chips | `UnifiedApp.preferred.source` (`AppSource.snap/deb/flatpak/appImage`) | "All" + one chip per `AppSource` present in the *current* list (chips for absent sources are not shown — no dead filters) |

Filtering is client-side over the fetched list (installed sets are tens of
items; no backend query needed). Filter state lives in `StateProvider`s next
to `unifiedInstalledProvider` so it survives refetch.

### 4. Sort — honest subset

`AppInfo` reality check (research 2026-09-27, all backends):

- `name`: REAL everywhere → **sort by name asc/desc: SHIPPED**.
- `installSizeBytes`: NULL from every backend → sort by size: OMITTED.
- install date: **no such field on `AppInfo`** → sort by date: OMITTED.

Omitting these is a feature, not a gap: the legacy page's date/size sorts
read snapd/PackageKit internals (`ManageAppData`), which don't exist in the
unified model. If a future contract version adds the fields, the sort control
gains options additively.

### 5. Refresh semantics

- **Manual**: pull-to-refresh (`RefreshIndicator`) → `ref.invalidate(unifiedInstalledProvider)`.
- **Automatic**: watch `activeOperationsProvider`. When a handle whose
  `app` belongs to the installed list reaches a terminal state
  (`Done`/`Failed`/`Cancelled` — completion *or* failure changes the
  installed set, or at least its displayed state), schedule a refetch:
  debounce 500ms to coalesce batch completions (update-all), then
  `ref.invalidate(unifiedInstalledProvider)`.
- **Stale-while-revalidate**: `unifiedInstalledProvider` becomes
  `keepAlive` + a separate `unifiedInstalledRefreshingProvider` (bool)
  drives a slim progress indicator in the header. The old list stays visible
  during refetch — no loading flash, no scroll jump. (Today the provider is
  not keep-alive and invalidate shows a full-page spinner; that UX is the
  thing being fixed.)
- **No refresh on non-terminal events**: progress/cancel/stall updates never
  invalidate; only terminal transitions do.

### 6. Layering

```
UnifiedManagePage (lib/manage/, UI layer)
  → unifiedInstalledProvider + filter/sort StateProviders (lib/manage/)
  → storeHostProvider.installed() (store_host)
```

New UI code lives under `lib/manage/` (UI layer per `dep_trace.py`) and
imports only `store_host` / `store_contracts` / app_center internals.
**No `backend_*` imports.** No contract changes — all provider-local.

## LLD

### 7. Providers (`lib/manage/unified_installed_provider.dart`)

```dart
// Existing, changed: add keepAlive
final unifiedInstalledProvider =
    FutureProvider<List<UnifiedApp>>((ref) {
      ref.keepAlive();   // stale-while-revalidate: list survives invalidate
      return ref.watch(storeHostProvider).installed();
    }, name: 'unifiedInstalledProvider');

// NEW: filter/sort state (auto-dispose is fine — page-scoped)
final unifiedManageSearchProvider =
    StateProvider<String>((_) => '', name: 'unifiedManageSearchProvider');

enum UnifiedManageSourceFilter { all, snap, deb, flatpak, appImage }
// maps to AppSource; `all` = no filter

final unifiedManageSourceFilterProvider =
    StateProvider<UnifiedManageSourceFilter>(
        (_) => UnifiedManageSourceFilter.all,
        name: 'unifiedManageSourceFilterProvider');

enum UnifiedManageSort { nameAsc, nameDesc }

final unifiedManageSortProvider = StateProvider<UnifiedManageSort>(
    (_) => UnifiedManageSort.nameAsc,
    name: 'unifiedManageSortProvider');

// NEW: filtered+sorted view (pure function of installed + filter state)
final unifiedManageVisibleAppsProvider = Provider<List<UnifiedApp>>((ref) {
  final apps = ref.watch(unifiedInstalledProvider).valueOrNull ?? [];
  final q = ref.watch(unifiedManageSearchProvider).trim().toLowerCase();
  final src = ref.watch(unifiedManageSourceFilterProvider);
  final sort = ref.watch(unifiedManageSortProvider);
  var out = apps.where((a) =>
      (q.isEmpty || a.preferred.name.toLowerCase().contains(q)) &&
      (src == UnifiedManageSourceFilter.all ||
          a.preferred.source.name == src.name));
  final list = out.toList()
    ..sort((x, y) => x.preferred.name
        .toLowerCase()
        .compareTo(y.preferred.name.toLowerCase()));
  return sort == UnifiedManageSort.nameAsc ? list : list.reversed.toList();
}, name: 'unifiedManageVisibleAppsProvider');

// NEW: refresh orchestration — watches operation terminals, debounces, invalidates
final unifiedInstalledRefreshTriggerProvider = Provider<void>((ref) {
  // implemented as a side-effect listener (see §8); provider exists so the
  // page has one obvious thing to watch.
}, name: 'unifiedInstalledRefreshTriggerProvider');
```

Filtering/sorting is a pure derived provider — trivially testable without
widgets.

### 8. Auto-refresh trigger (the only tricky part)

Implementation: a `ref.listen` inside `UnifiedManagePage.build` (or a
dedicated `ConsumerWidget` `_RefreshTrigger`) on `activeOperationsProvider`:

```dart
ref.listen(activeOperationsProvider, (prev, next) {
  final before = prev?.valueOrNull ?? const [];
  final after = next.valueOrNull ?? const [];
  // handles that were in-flight and are now gone = reached terminal
  // (host removes handles from the active list on terminal — verified
  //  pattern from the progress-UX slice, UnifiedInstallButton)
  final completed = before.where((h) =>
      h.current.isTerminal == false &&
      after.every((a) => a.app != h.app));
  if (completed.isNotEmpty) _debouncedInvalidate();
});
```

Notes:

- **Why "disappeared from active list" instead of `isTerminal` on the
  handle**: the host removes terminal handles from `activeOperations()`; the
  row-button pattern (`prev != null && handle == null && prev.current.isTerminal`)
  already relies on this. Same signal, reused.
- **Debounce**: 500ms `Timer`; each new completion resets it (coalesces
  update-all batches into one refetch). Timer cancelled on widget dispose.
- **Which operations**: any handle whose `app` identity matches an installed
  app — install/remove/update all mutate the installed set. No kind filter
  needed: the active list only contains operations the user started from
  these pages.
- **Guard**: skip invalidate while `unifiedInstalledProvider` is already
  loading (avoid refetch storms).

Edge: `Cancelled` also triggers refresh — correct, because a cancelled
remove may have partially changed state, and refresh is cheap and idempotent.

### 9. UI structure (`unified_manage_page.dart`)

```
UnifiedManagePage (ConsumerWidget)
├─ _RefreshTrigger (watches activeOperationsProvider, side-effect only)
├─ header (existing)
├─ _ManageToolbar: search field + source chips + sort menu
└─ installed.when → SliverList of _InstalledAppTile (existing, unchanged)
```

- `_ManageToolbar` reuses the legacy `_DebouncedSearchField` constants
  (`kSearchFieldContentPadding` etc. from `widgets.dart`).
- Source chips: `FilterChip`s built from the sources present in the
  *unfiltered* list (`unifiedInstalledProvider.valueOrNull`), "All" first.
- Sort: `MenuButtonBuilder<UnifiedManageSort>` (same pattern as legacy
  `manage_page.dart`) with two entries.
- Refreshing indicator: `ref.watch(unifiedInstalledProvider)` —
  `isRefreshing || isReloading` → slim `LinearProgressIndicator` under the
  header (keep-alive provider gives us `isRefreshing` instead of `isLoading`).
- Pull-to-refresh: wrap the scroll view in `RefreshIndicator`
  (`onRefresh: () async { ref.invalidate(unifiedInstalledProvider); await ref.read(unifiedInstalledProvider.future); }`).

### 10. i18n (app_en.arb only — Weblate handles the rest)

- `unifiedManagePageSearchHint` — "Search installed apps"
- `unifiedManagePageSourceAll` — "All"
- `unifiedManagePageSortLabel` — "Sort"
- `unifiedManageSortNameAsc` — "Name (A–Z)"
- `unifiedManageSortNameDesc` — "Name (Z–A)"
- `unifiedManagePageRefreshingLabel` — "Refreshing…" (a11y)

### 11. Tests

- **Provider tests** (`unified_installed_provider_test.dart`): filter by
  search substring (case-insensitive), filter by each source, source filter
  `all`, sort asc/desc ordering, combined filter+sort — all against a fake
  `UnifiedApp` list, no widgets.
- **Widget tests** (`unified_manage_page_test.dart`): typing in search narrows
  tiles; tapping a source chip filters; sort menu reorders; pull-to-refresh
  invalidates (fake host counts `installed()` calls); **terminal operation →
  refetch** (fake handle removed from active list → `installed()` called
  again after debounce — use fake async / short debounce override);
  **non-terminal event → no refetch** (progress event on the handle changes
  nothing).
- Debounce must be injectable/fake-timer driven — no real 500ms sleeps in tests.

### 12. Acceptance criteria

- [ ] Typing filters the installed list by name; clearing restores it.
- [ ] Source chips show only sources present in the list; "All" default.
- [ ] Sort toggles A–Z / Z–A; no size/date options anywhere.
- [ ] Completing (or failing/cancelling) a remove/update triggers exactly one
        refetch (debounced); progress events trigger none.
- [ ] Pull-to-refresh refetches; old list stays visible during refetch.
- [ ] `melos test`, `analyze --fatal-infos`, `format:exclude` green.
- [ ] `dep_trace.py`: zero new violations. No `backend_*` imports in UI.
