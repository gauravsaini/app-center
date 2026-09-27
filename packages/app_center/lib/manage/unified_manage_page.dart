/// Unified Manage page (installed apps) for the manage-strangle slice.
///
/// Rendered instead of the legacy Manage page when the
/// `pages.manage.unified` flag is on.
/// Lists the [UnifiedApp]s from [StoreHost.installed()] with one row per
/// app: name, installed version, and a backend badge. Removal is driven
/// through the host via [UnifiedInstallButton] (installed apps resolve
/// to [OperationKind.remove]) — never backend services directly.
///
/// States: loading spinner, [ErrorView] with retry (the host itself
/// never throws, but the provider can still fail above the host), and
/// an empty state when no backend reports installed apps.
///
/// No `backend_*` import by design: this file sees only the host, the
/// contracts, and app_center internals.
library;

import 'package:app_center/error/error.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/layout.dart';
import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';
import 'package:yaru/yaru.dart';

/// Installed-apps list sourced from the unified store.
///
/// Shown only when `pages.manage.unified` is on; the legacy Manage page
/// stays the default until this view reaches parity (updates sections,
/// local deb handling, filters — see the honest-gaps note on the slice).
class UnifiedManagePage extends ConsumerWidget {
  const UnifiedManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final installed = ref.watch(unifiedInstalledProvider);

    return ResponsiveLayoutScrollView(
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
        installed.when(
          data: (apps) => apps.isEmpty
              ? const SliverToBoxAdapter(child: _EmptyState())
              : SliverList.builder(
                  itemCount: apps.length,
                  itemBuilder: (context, index) =>
                      _InstalledAppTile(app: apps[index]),
                ),
          error: (error, stack) => SliverToBoxAdapter(
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
