import 'package:app_center/explore/explore.dart';
import 'package:app_center/manage/local_deb_providers.dart';
import 'package:app_center/manage/local_deb_updates_model.dart';
import 'package:app_center/manage/manage.dart';
import 'package:app_center/manage/snap_updates_model.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

import 'test_utils.dart';

void main() {
  tearDown(resetAllServices);

  /// Pumps every nav tile from [storePagesProvider] with the snap kill
  /// switch forced to [snapEnabled]. The Manage tile's update badge is
  /// stubbed to zero updates so no D-Bus services are needed.
  Future<void> pumpTiles(
    WidgetTester tester, {
    required bool snapEnabled,
  }) async {
    final flags = MapFeatureFlags()
      ..setFlag('backend.snap.enabled', snapEnabled);
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          snapUpdatesModelProvider.overrideWith(_StubSnapUpdatesModel.new),
          localDebUpdatesModelProvider.overrideWith(
            _StubLocalDebUpdatesModel.new,
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            final pages = ref.watch(storePagesProvider);
            // Column (not ListView): the spacer entry is a raw Spacer,
            // which needs a Flex ancestor with bounded height — the
            // Scaffold body provides it.
            return Column(
              children: [
                for (final page in pages) page.tileBuilder(context, false),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
  }

  test('backendEnabledProvider reads the seeded snap kill switch', () {
    final container = createContainer(
      overrides: [
        storeFlagsProvider.overrideWithValue(
          MapFeatureFlags()..setFlag('backend.snap.enabled', false),
        ),
      ],
    );

    expect(container.read(backendEnabledProvider('snap')), isFalse);
    expect(container.read(backendEnabledProvider('flatpak')), isTrue);
    expect(container.read(backendEnabledProvider('deb')), isTrue);
    // The filter follows the same flag: 9 tiles today, 6 without snap.
    expect(container.read(storePagesProvider).length, 6);
  });

  test('backendEnabledProvider is all-on with default flags', () {
    final container = createContainer();

    expect(container.read(backendEnabledProvider('snap')), isTrue);
    expect(container.read(storePagesProvider).length, 9);
  });

  testWidgets(
    'snap disabled hides the snap-category tiles, keeps Manage+Explore',
    (tester) async {
      await pumpTiles(tester, snapEnabled: false);

      final l10n = tester.l10n;
      expect(
        find.text(SnapCategoryEnum.featured.localize(l10n)),
        findsNothing,
      );
      expect(
        find.text(SnapCategoryEnum.productivity.localize(l10n)),
        findsNothing,
      );
      expect(
        find.text(SnapCategoryEnum.development.localize(l10n)),
        findsNothing,
      );
      // Manage stays unconditionally; Explore is not a snap-category tile.
      expect(
        find.text(ManagePage.label(tester.context)),
        findsOneWidget,
      );
      expect(
        find.text(ExplorePage.label(tester.context)),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'snap enabled shows all tiles (today\'s behavior)',
    (tester) async {
      await pumpTiles(tester, snapEnabled: true);

      final l10n = tester.l10n;
      expect(
        find.text(SnapCategoryEnum.featured.localize(l10n)),
        findsOneWidget,
      );
      expect(
        find.text(SnapCategoryEnum.productivity.localize(l10n)),
        findsOneWidget,
      );
      expect(
        find.text(SnapCategoryEnum.development.localize(l10n)),
        findsOneWidget,
      );
      expect(
        find.text(ManagePage.label(tester.context)),
        findsOneWidget,
      );
    },
  );
}

/// Stub notifiers for the Manage tile's update badge: zero updates, no
/// D-Bus services. The `late final` service fields are never touched.
class _StubSnapUpdatesModel extends SnapUpdatesModel {
  @override
  Future<SnapListState> build() async => SnapListState();
}

class _StubLocalDebUpdatesModel extends LocalDebUpdatesModel {
  @override
  Future<List<LocalDebInfo>> build() async => [];
}
