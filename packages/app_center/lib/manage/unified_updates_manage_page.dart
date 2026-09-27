/// Manage page with both strangler flags on: the updates section and
/// the installed list are both sourced from [StoreHost]
/// (`pages.updates.unified` + `pages.manage.unified`).
///
/// Composes [UnifiedUpdatesSection] above the unified installed list.
/// The installed-app tile mirrors [UnifiedManagePage]'s tile and is
/// intentionally duplicated rather than shared: the two pages belong
/// to different strangler slices and must not couple.
///
/// No `backend_*` import by design: this file sees only the host, the
/// contracts, and app_center internals.
library;

import 'package:app_center/error/error.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/layout.dart';
import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:app_center/manage/unified_manage_page.dart';
import 'package:app_center/manage/unified_updates_provider.dart';
import 'package:app_center/manage/unified_updates_section.dart';
import 'package:app_center/manage/update_poll_scheduler.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';
import 'package:yaru/yaru.dart';

/// Manage page: unified updates section + unified installed list.
///
/// Shown only when both `pages.updates.unified` and
/// `pages.manage.unified` are on.
class UnifiedUpdatesManagePage extends ConsumerWidget {
  const UnifiedUpdatesManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final installed = ref.watch(unifiedInstalledProvider);

    return RefreshIndicator(
      onRefresh: () => _refreshUpdates(ref),
      child: ResponsiveLayoutScrollView(
        // Lets pull-to-refresh trigger even when the list is short.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
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
                const SizedBox(height: kMarginLarge),
              ],
            ),
          ),

          // Unified updates surface (replaces the legacy updates sections).
          const UnifiedUpdatesSection(),

          SliverList.list(
            children: [
              const SizedBox(height: kSectionSpacing),
              Text(
                l10n.managePageInstalledAndUpdatedLabel,
                style: textTheme.titleMedium!.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: kMarginLarge),
            ],
          ),

          installed.when(
            data: (apps) => apps.isEmpty
                ? const SliverToBoxAdapter(child: _EmptyState())
                : SliverList.builder(
                    itemCount: apps.length,
                    itemBuilder: (context, index) =>
                        _InstalledAppTile(app: apps[index]),
                  ),
            error: (error, stack) => SliverToBoxAdapter(
              // ErrorView's Spacers need bounded height; IntrinsicHeight
              // sizes it to its content inside the unbounded sliver.
              child: IntrinsicHeight(
                child: ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(unifiedInstalledProvider),
                ),
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

/// Manual pull-to-refresh for the updates surface (update-polling.md
/// §6): mirrors the installed list — invalidate, await the refetch so
/// the indicator tracks real progress, then tell the poll scheduler so
/// the manual check resets the countdown.
///
/// The invalidate-while-loading guard (manage-polish) makes this a
/// no-op while a check is already in flight.
Future<void> _refreshUpdates(WidgetRef ref) async {
  final updates = ref.read(unifiedUpdatesProvider);
  if (!updates.isLoading && !updates.isRefreshing && !updates.isReloading) {
    ref.invalidate(unifiedUpdatesProvider);
    // Await the refetch so the indicator tracks real progress instead
    // of dismissing immediately.
    await ref.read(unifiedUpdatesProvider.future);
  }
  ref.read(updatePollSchedulerProvider.notifier).onManualRefresh();
}

/// One installed app: backend badge, name + installed version, and the
/// host-driven remove action.
///
/// Mirrors [UnifiedManagePage]'s tile; duplicated (not shared) so the
/// updates slice never couples to the installed-apps slice.
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

/// Which backend owns the app. Opaque source label, same as the
/// updates section's badge.
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
