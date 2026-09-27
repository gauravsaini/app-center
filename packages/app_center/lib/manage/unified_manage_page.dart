/// Unified Manage page (installed apps) for the manage-strangle slice.
///
/// Rendered instead of the legacy Manage page when the
/// `pages.manage.unified` flag is on.
/// Lists the [UnifiedApp]s from [StoreHost.installed()] with one row per
/// app: name, installed version, and a backend badge. Removal is driven
/// through the host via [UnifiedInstallButton] (installed apps resolve
/// to [OperationKind.remove]) — never backend services directly.
///
/// Affordances: debounced free-text search, per-source filter chips
/// (only for sources present in the list), name A–Z/Z–A sort,
/// pull-to-refresh, and automatic refetch when an install/remove/update
/// operation reaches a terminal state.
///
/// States: loading spinner, [ErrorView] with retry (the host itself
/// never throws, but the provider can still fail above the host), and
/// an empty state when no backend reports installed apps. The provider
/// is keep-alive, so refetches keep the old list visible behind a slim
/// progress indicator instead of flashing a full-page spinner.
///
/// No `backend_*` import by design: this file sees only the host, the
/// contracts, and app_center internals.
library;

import 'dart:async';

import 'package:app_center/constants.dart';
import 'package:app_center/error/error.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/layout.dart';
import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_widgets/ubuntu_widgets.dart';
import 'package:yaru/yaru.dart';

/// Installed-apps list sourced from the unified store.
///
/// Shown only when `pages.manage.unified` is on; the legacy Manage page
/// stays the default until this view reaches parity (updates sections,
/// local deb handling — see the honest-gaps note on the slice).
class UnifiedManagePage extends ConsumerWidget {
  const UnifiedManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final installed = ref.watch(unifiedInstalledProvider);
    final visibleApps = ref.watch(unifiedManageVisibleAppsProvider);
    final refreshing = installed.isRefreshing || installed.isReloading;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(unifiedInstalledProvider);
        // Await the refetch so the indicator tracks real progress
        // instead of dismissing immediately.
        await ref.read(unifiedInstalledProvider.future);
      },
      child: ResponsiveLayoutScrollView(
        // Lets pull-to-refresh trigger even when the list is short.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const _RefreshTrigger(),
          SliverPadding(
            padding: const EdgeInsets.only(top: kPagePadding),
            sliver: SliverList.list(
              children: [
                Semantics(
                  header: true,
                  focused: true,
                  child: Text(
                    l10n.managePageLabel,
                    style: textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: kSpacing),
                Text(
                  l10n.managePageInstalledAndUpdatedLabel,
                  style: textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: kMarginLarge),
              ],
            ),
          ),
          // Slim progress bar while the keep-alive provider refetches
          // behind the still-visible list.
          if (refreshing)
            SliverToBoxAdapter(
              child: Semantics(
                label: l10n.unifiedManagePageRefreshingLabel,
                child: const LinearProgressIndicator(),
              ),
            ),
          const SliverToBoxAdapter(child: _ManageToolbar()),
          installed.when(
            data: (_) =>
                visibleApps.isEmpty && (installed.valueOrNull?.isEmpty ?? true)
                ? const SliverToBoxAdapter(child: _EmptyState())
                : SliverList.builder(
                    itemCount: visibleApps.length,
                    itemBuilder: (context, index) =>
                        _InstalledAppTile(app: visibleApps[index]),
                  ),
            error: (error, stack) => IntrinsicHeight(
              // ErrorView's Spacers need bounded height; IntrinsicHeight
              // sizes it to its content inside the unbounded sliver.
              child: ErrorView(
                error: error,
                onRetry: () => ref.invalidate(unifiedInstalledProvider),
              ),
            ),
            loading: () => const SliverToBoxAdapter(
              child: Center(child: YaruCircularProgressIndicator()),
            ),
          ),

          // Bottom spacing
          const SliverPadding(
            padding: EdgeInsets.only(bottom: kPagePadding),
          ),
        ],
      ),
    );
  }
}

/// Watches [activeOperationsProvider] and refetches the installed list
/// when an operation reaches a terminal state.
///
/// Terminal detection reuses the row-button signal: the host drops
/// terminal handles from the active list, so a handle that was in-flight
/// and is now gone completed (or failed / was cancelled — all of which
/// can change the installed set, so all refetch). Progress and other
/// non-terminal updates never refetch.
///
/// Completions are debounced ([unifiedManageRefreshDebounceProvider]) to
/// coalesce batches (e.g. update-all) into a single refetch, and the
/// refetch is skipped while a fetch is already in flight.
class _RefreshTrigger extends ConsumerStatefulWidget {
  const _RefreshTrigger();

  @override
  ConsumerState<_RefreshTrigger> createState() => _RefreshTriggerState();
}

class _RefreshTriggerState extends ConsumerState<_RefreshTrigger> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleRefetch() {
    final debounce = ref.read(unifiedManageRefreshDebounceProvider);
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      // Guard against refetch storms: never invalidate while a fetch is
      // already in flight.
      final installed = ref.read(unifiedInstalledProvider);
      if (installed.isLoading ||
          installed.isRefreshing ||
          installed.isReloading) {
        return;
      }
      ref.invalidate(unifiedInstalledProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeOperationsProvider, (prev, next) {
      final before = prev?.valueOrNull ?? const <OperationHandle>[];
      final after = next.valueOrNull ?? const <OperationHandle>[];
      // Handles that were in-flight and are now gone reached a terminal
      // state (host removes them from the active list on terminal).
      final completed = before.where(
        (h) => !h.current.isTerminal && after.every((a) => a.app != h.app),
      );
      if (completed.isNotEmpty) _scheduleRefetch();
    });
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }
}

/// Search field + source filter chips + sort menu for the unified list.
///
/// Source chips are built from the sources present in the *unfiltered*
/// installed list — never dead filters. Filter/sort state lives in
/// [StateProvider]s next to [unifiedInstalledProvider] so it survives
/// refetch.
class _ManageToolbar extends ConsumerWidget {
  const _ManageToolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final installed = ref.watch(unifiedInstalledProvider).valueOrNull;
    final sourceFilter = ref.watch(unifiedManageSourceFilterProvider);
    final sort = ref.watch(unifiedManageSortProvider);

    // One chip per source present in the unfiltered list.
    final sources = <UnifiedManageSourceFilter>{};
    for (final app in installed ?? const <UnifiedApp>[]) {
      final filter = UnifiedManageSourceFilterX.fromAppSource(
        app.preferred.source,
      );
      if (filter != null) sources.add(filter);
    }
    final chips = [
      UnifiedManageSourceFilter.all,
      for (final s in UnifiedManageSourceFilter.values)
        if (s != UnifiedManageSourceFilter.all && sources.contains(s)) s,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DebouncedSearchField(hintText: l10n.unifiedManagePageSearchHint),
        const SizedBox(height: kSpacingSmall),
        Wrap(
          spacing: kSpacingSmall,
          runSpacing: kSpacingSmall,
          children: [
            for (final chip in chips)
              FilterChip(
                label: Text(
                  chip == UnifiedManageSourceFilter.all
                      ? l10n.unifiedManagePageSourceAll
                      : chip.name,
                ),
                selected: sourceFilter == chip,
                onSelected: (_) =>
                    ref.read(unifiedManageSourceFilterProvider.notifier).state =
                        chip,
              ),
          ],
        ),
        const SizedBox(height: kSpacingSmall),
        Row(
          children: [
            Text(l10n.unifiedManagePageSortLabel),
            const SizedBox(width: kSpacingSmall),
            MenuButtonBuilder<UnifiedManageSort>(
              values: UnifiedManageSort.values,
              selected: sort,
              itemBuilder: (context, value, child) =>
                  Text(value.localize(l10n)),
              onSelected: (value) =>
                  ref.read(unifiedManageSortProvider.notifier).state = value,
              expanded: false,
              child: Text(sort.localize(l10n)),
            ),
          ],
        ),
        const SizedBox(height: kMarginLarge),
      ],
    );
  }
}

/// Search field with a 200ms debounce (same pattern as the legacy
/// Manage page's `_DebouncedSearchField`), writing into
/// [unifiedManageSearchProvider].
class _DebouncedSearchField extends ConsumerStatefulWidget {
  const _DebouncedSearchField({required this.hintText});

  final String hintText;

  @override
  ConsumerState<_DebouncedSearchField> createState() =>
      _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends ConsumerState<_DebouncedSearchField> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      ref.read(unifiedManageSearchProvider.notifier).state = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 170),
      child: TextFormField(
        style: Theme.of(context).textTheme.bodyMedium,
        textAlignVertical: TextAlignVertical.center,
        cursorWidth: 1,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: kSearchFieldContentPadding,
          prefixIcon: kSearchFieldPrefixIcon,
          prefixIconConstraints: kSearchFieldIconConstraints,
          hintText: widget.hintText,
        ),
        onChanged: _onSearchChanged,
      ),
    );
  }
}

/// One installed app: backend badge, name + installed version, and the
/// host-driven remove action.
class _InstalledAppTile extends StatelessWidget {
  const _InstalledAppTile({required this.app});

  final UnifiedApp app;

  @override
  Widget build(BuildContext context) {
    final info = app.preferred;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpacingSmall),
      child: Row(
        children: [
          _BackendBadge(backendId: info.identity.backendId),
          const SizedBox(width: kSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  info.name,
                  style: textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (info.installedVersion != null)
                  Text(
                    info.installedVersion!,
                    style: textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: kSpacing),
          // Installed apps resolve to OperationKind.remove inside the
          // button: progress, cancel, and typed-error retry come free.
          SizedBox(
            width: 160,
            child: UnifiedInstallButton(app: app),
          ),
        ],
      ),
    );
  }
}

/// Which backend owns the app. The UI never learns what a snap or a deb
/// is — it only shows the backend's id as an opaque source label.
class _BackendBadge extends StatelessWidget {
  const _BackendBadge({required this.backendId});

  final String backendId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        backendId,
        style: theme.textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kPagePadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.unifiedManagePageEmptyTitle,
            style: textTheme.headlineSmall,
          ),
          const SizedBox(height: kSpacingSmall),
          Text(
            l10n.unifiedManagePageEmptyDescription,
            style: textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
