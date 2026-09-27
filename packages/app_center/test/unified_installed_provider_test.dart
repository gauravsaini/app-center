import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

/// Provider tests for the unified Manage page polish: search filter,
/// source filter, sort order, and combinations — all against a fake
/// [UnifiedApp] list, no widgets.
void main() {
  tearDown(resetAllServices);

  final apps = [
    _app('Firefox', AppSource.snap),
    _app('VLC media player', AppSource.deb),
    _app('firewall-config', AppSource.flatpak),
    _app('Zotero', AppSource.snap),
    _app('delta chat', AppSource.appImage),
  ];

  Future<ProviderContainer> containerWith({
    String search = '',
    UnifiedManageSourceFilter source = UnifiedManageSourceFilter.all,
    UnifiedManageSort sort = UnifiedManageSort.nameAsc,
  }) async {
    final container = createContainer(
      overrides: [
        unifiedInstalledProvider.overrideWith((ref) async => apps),
      ],
    );
    // Let the installed list resolve so valueOrNull is populated.
    await container.read(unifiedInstalledProvider.future);
    container.read(unifiedManageSearchProvider.notifier).state = search;
    container.read(unifiedManageSourceFilterProvider.notifier).state = source;
    container.read(unifiedManageSortProvider.notifier).state = sort;
    return container;
  }

  List<String> namesOf(List<UnifiedApp> apps) =>
      apps.map((a) => a.preferred.name).toList();

  group('unifiedManageVisibleAppsProvider', () {
    test('defaults: all apps, sorted name A-Z', () async {
      final container = await containerWith();
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        [
          'delta chat',
          'Firefox',
          'firewall-config',
          'VLC media player',
          'Zotero',
        ],
      );
    });

    test('search filters by name substring, case-insensitive', () async {
      final container = await containerWith(search: 'FIRE');
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['Firefox', 'firewall-config'],
      );
    });

    test('search trims surrounding whitespace', () async {
      final container = await containerWith(search: '  vlc  ');
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['VLC media player'],
      );
    });

    test('search with no matches yields an empty list', () async {
      final container = await containerWith(search: 'no-such-app');
      expect(container.read(unifiedManageVisibleAppsProvider), isEmpty);
    });

    test('source filter snap keeps only snaps', () async {
      final container = await containerWith(
        source: UnifiedManageSourceFilter.snap,
      );
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['Firefox', 'Zotero'],
      );
    });

    test('source filter deb keeps only debs', () async {
      final container = await containerWith(
        source: UnifiedManageSourceFilter.deb,
      );
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['VLC media player'],
      );
    });

    test('source filter flatpak keeps only flatpaks', () async {
      final container = await containerWith(
        source: UnifiedManageSourceFilter.flatpak,
      );
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['firewall-config'],
      );
    });

    test('source filter appImage keeps only appimages', () async {
      final container = await containerWith(
        source: UnifiedManageSourceFilter.appImage,
      );
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['delta chat'],
      );
    });

    test('source filter all disables the filter', () async {
      final container = await containerWith();
      expect(
        container.read(unifiedManageVisibleAppsProvider),
        hasLength(apps.length),
      );
    });

    test('sort nameDesc reverses the order', () async {
      final container = await containerWith(sort: UnifiedManageSort.nameDesc);
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        [
          'Zotero',
          'VLC media player',
          'firewall-config',
          'Firefox',
          'delta chat',
        ],
      );
    });

    test('combined: search + source filter + sort', () async {
      final container = await containerWith(
        search: 'f',
        source: UnifiedManageSourceFilter.snap,
        sort: UnifiedManageSort.nameDesc,
      );
      expect(
        namesOf(container.read(unifiedManageVisibleAppsProvider)),
        ['Firefox'],
      );
    });
  });

  group('UnifiedManageSourceFilter mapping', () {
    test('each filter maps to its contract AppSource', () {
      expect(UnifiedManageSourceFilter.snap.appSource, AppSource.snap);
      expect(UnifiedManageSourceFilter.deb.appSource, AppSource.deb);
      expect(
        UnifiedManageSourceFilter.flatpak.appSource,
        AppSource.flatpak,
      );
      expect(
        UnifiedManageSourceFilter.appImage.appSource,
        AppSource.appImage,
      );
      expect(UnifiedManageSourceFilter.all.appSource, isNull);
    });

    test('fromAppSource round-trips; unknown has no chip', () {
      for (final filter in UnifiedManageSourceFilter.values) {
        final source = filter.appSource;
        if (source == null) continue;
        expect(
          UnifiedManageSourceFilterX.fromAppSource(source),
          filter,
        );
      }
      expect(
        UnifiedManageSourceFilterX.fromAppSource(AppSource.unknown),
        isNull,
      );
    });
  });
}

UnifiedApp _app(String name, AppSource source) => UnifiedApp(
  groupId: 'fake:$name',
  variants: [
    AppInfo(
      identity: AppIdentity(backendId: 'fake', nativeId: name),
      name: name,
      summary: 'A stub installed app.',
      iconUrl: '',
      source: source,
      installedVersion: '1.0',
    ),
  ],
);
