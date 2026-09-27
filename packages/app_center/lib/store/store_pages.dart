import 'package:app_center/about/about.dart';
import 'package:app_center/explore/explore.dart';
import 'package:app_center/games/games.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/manage/local_deb_updates_model.dart';
import 'package:app_center/manage/manage.dart';
import 'package:app_center/manage/snap_updates_model.dart';
import 'package:app_center/search/search.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';

class _NavigationTile extends StatelessWidget {
  const _NavigationTile({
    required this.title,
    this.leading,
    this.trailing,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listTileTheme = theme.listTileTheme;
    final scope = YaruMasterTileScope.maybeOf(context);
    final isSelected = scope?.selected ?? false;

    final backgroundColor = isSelected
        ? listTileTheme.selectedTileColor
        : listTileTheme.tileColor;

    return YaruMasterTile(
      title: title,
      decoration: BoxDecoration(
        border: BoxBorder.all(color: Colors.transparent, width: 2),
        borderRadius: const BorderRadius.all(
          Radius.circular(kYaruButtonRadius),
        ),
        color: backgroundColor,
      ),
      focusDecoration: BoxDecoration(
        border: BoxBorder.all(color: theme.primaryColor, width: 2),
        borderRadius: const BorderRadius.all(
          Radius.circular(kYaruButtonRadius),
        ),
        color: backgroundColor ?? theme.cardColor,
      ),
      leading: leading,
      trailing: trailing,
      selected: isSelected,
    );
  }
}

final displayedCategories = [
  SnapCategoryEnum.featured,
  SnapCategoryEnum.productivity,
  SnapCategoryEnum.development,
];

typedef StorePage = ({
  Widget Function(BuildContext context, bool selected) tileBuilder,
  Widget Function(BuildContext context, YaruWindowTitleBar title) pageBuilder,
});

// Page entries, split so [storePagesProvider] can drop the legacy
// snap-category tiles when the snap backend is disabled
// (docs/architecture/platform-detection.md §6).
final StorePage _explorePage = (
  tileBuilder: (context, selected) => _NavigationTile(
    leading: Icon(ExplorePage.icon(selected)),
    title: Text(ExplorePage.label(context)),
  ),
  pageBuilder: (_, title) => YaruDetailPage(
    appBar: title,
    body: const ExplorePage(),
  ),
);

// The legacy snap-category tiles (Featured/Productivity/Development):
// they bypass the host via legacy snap providers, so the shell hides
// them where the snap backend is disabled.
final List<StorePage> _snapCategoryPages = [
  for (final category in displayedCategories)
    (
      tileBuilder: (context, selected) => _NavigationTile(
        leading: Icon(category.icon(selected)),
        title: Text(category.localize(AppLocalizations.of(context))),
      ),
      pageBuilder: (_, title) => YaruDetailPage(
        appBar: title,
        body: SearchPage(category: category.categoryName),
      ),
    ),
];

final StorePage _gamesPage = (
  tileBuilder: (context, selected) => _NavigationTile(
    leading: Icon(GamesPage.icon(selected)),
    title: Text(GamesPage.label(context)),
  ),
  pageBuilder: (_, title) => YaruDetailPage(
    appBar: title,
    body: const GamesPage(),
  ),
);

final StorePage _spacerPage = (
  tileBuilder: (context, selected) => const Spacer(),
  pageBuilder: (_, title) => const SizedBox.shrink(),
);

final StorePage _managePage = (
  tileBuilder: (context, selected) => _NavigationTile(
    leading: Icon(ManagePage.icon(selected)),
    title: Text(ManagePage.label(context)),
    trailing: Consumer(
      builder: (context, ref, child) {
        // Strangler-fig slice: when `pages.updates.unified` is on, the
        // nav badge counts updates from StoreHost.checkUpdates() via
        // unifiedUpdatesProvider. Flag off (the default) keeps the
        // legacy snap/deb count below byte-identical.
        if (ref.watch(storeFlagsProvider).isEnabled('pages.updates.unified')) {
          final updates = ref.watch(unifiedUpdatesProvider);
          final count = updates.valueOrNull?.length ?? 0;

          return count > 0
              ? Badge(label: Text('$count'))
              : const SizedBox.shrink();
        }

        final snapUpdates = ref.watch(snapUpdatesModelProvider);
        final debUpdates = ref.watch(localDebUpdatesModelProvider);

        final snapCount = snapUpdates.valueOrNull?.length ?? 0;
        final debCount = debUpdates.valueOrNull?.length ?? 0;
        final totalCount = snapCount + debCount;

        return totalCount > 0
            ? Badge(label: Text('$totalCount'))
            : const SizedBox.shrink();
      },
    ),
  ),
  pageBuilder: (_, title) => YaruDetailPage(
    appBar: title,
    body: const ManagePage(),
  ),
);

final StorePage _aboutPage = (
  tileBuilder: (context, selected) => _NavigationTile(
    leading: Icon(AboutPage.icon(selected)),
    title: Text(AboutPage.label(context)),
  ),
  pageBuilder: (_, title) => YaruDetailPage(
    appBar: title,
    body: const AboutPage(),
  ),
);

/// The shell's page list.
///
/// The legacy snap-category tiles (Featured/Productivity/Development)
/// are hidden when the snap backend is disabled
/// (docs/architecture/platform-detection.md §6) — they bypass the host
/// via legacy snap providers. Manage stays unconditionally: it hosts
/// the unified pages, which degrade per-backend already. No new
/// user-visible strings — hiding a tile needs none.
final storePagesProvider = Provider<List<StorePage>>(
  (ref) {
    final snapEnabled = ref.watch(backendEnabledProvider('snap'));
    return [
      _explorePage,
      if (snapEnabled) ..._snapCategoryPages,
      _gamesPage,
      _spacerPage,
      _managePage,
      _aboutPage,
    ];
  },
  name: 'storePagesProvider',
);
