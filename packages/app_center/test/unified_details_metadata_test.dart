/// Widget tests for the Phase 3 slice 5 community metadata sections on
/// the unified details page (docs/architecture/phase3-slice5.md §3).
///
/// - flag pair on + verified entry: the community description wins
///   (tagged), screenshots union community-first deduped by URL,
///   permissions block after the install button, rating with count
/// - backend-only description when the community has none; the header
///   summary stays backend data
/// - missing metadata: today's page bit-for-bit, no empty states
/// - flag off with metadata present: the page is unchanged
/// - variant picker unchanged; the community block renders once under
///   the switcher
///
/// Fixtures go through the real [CommunityAppMetadata.fromJson] parse
/// path — the test never names the host-internal sub-types. Never
/// touches a real backend or the network: the host is faked.
library;

import 'package:app_center/details/details.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'test_utils.dart';

void main() {
  setUp(registerMockRatingsService);
  tearDown(resetAllServices);

  const canonicalId = CanonicalAppId(
    CanonicalIdScheme.appstream,
    'org.test.app',
  );
  const snapIdentity = AppIdentity(backendId: 'snap', nativeId: 'test-snap');

  /// Full community entry: description, screenshots (one URL shared
  /// with the backend), curated permissions, rating.
  CommunityAppMetadata communityMetadata() => CommunityAppMetadata.fromJson({
    'canonicalId': 'appstream:org.test.app',
    'summary': 'Community summary — never shown in the header.',
    'description': 'Community description of the test app.',
    'screenshots': [
      {'url': 'https://example.com/c1.png', 'caption': 'Start page'},
      {
        'url': 'https://example.com/shared.png',
        'caption': 'Shared shot',
      },
    ],
    'permissions': {
      'sandboxing': 'sandboxed',
      'capabilities': ['network', 'home.read'],
      'source': 'curated-review',
    },
    'rating': {'mean': 4.3, 'count': 128},
  });

  UnifiedApp singleVariantApp() => const UnifiedApp(
    groupId: 'appstream:org.test.app',
    canonicalId: canonicalId,
    variants: [
      AppInfo(
        identity: snapIdentity,
        name: 'Test App',
        summary: 'backend summary',
        iconUrl: '',
        source: AppSource.snap,
      ),
    ],
  );

  Future<void> pumpMetadataDetails(
    WidgetTester tester, {
    CommunityAppMetadata? metadata,
    bool metadataFlag = true,
    UnifiedApp? app,
  }) {
    return tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeHostProvider.overrideWithValue(
            _MetadataHost(metadata: metadata),
          ),
          storeFlagsProvider.overrideWithValue(
            MapFeatureFlags({
              'phase3.identity.enabled': true,
              if (metadataFlag) 'phase3.metadata.enabled': true,
            }),
          ),
        ],
        child: UnifiedDetailsPage(
          identity: snapIdentity,
          app: app ?? singleVariantApp(),
        ),
      ),
    );
  }

  /// NetworkImage URLs in render order.
  List<String> imageUrls(WidgetTester tester) => tester
      .widgetList<Image>(find.byType(Image))
      .map((w) => (w.image as NetworkImage).url)
      .toList();

  test('metadataEnabledProvider needs both flags', () {
    bool readWith(Map<String, Object> seed) {
      final container = createContainer(
        overrides: [
          storeFlagsProvider.overrideWithValue(MapFeatureFlags(seed)),
        ],
      );
      return container.read(metadataEnabledProvider);
    }

    expect(readWith({}), isFalse);
    expect(readWith({'phase3.identity.enabled': true}), isFalse);
    expect(readWith({'phase3.metadata.enabled': true}), isFalse);
    expect(
      readWith({
        'phase3.identity.enabled': true,
        'phase3.metadata.enabled': true,
      }),
      isTrue,
    );
  });

  testWidgets('community metadata renders per the precedence contract', (
    tester,
  ) async {
    await pumpMetadataDetails(tester, metadata: communityMetadata());
    await tester.pumpAndSettle();

    // Description: community wins, tagged; the backend description is
    // absent from the description block.
    expect(
      find.text('Community description of the test app.'),
      findsOneWidget,
    );
    expect(
      find.text('Backend description of the test app.'),
      findsNothing,
    );
    expect(
      find.text(tester.l10n.communityMetadataCuratedTag),
      findsOneWidget,
    );

    // The header summary stays backend data (identity-critical, not
    // editorial) — the community summary is never shown.
    expect(find.text('backend summary'), findsOneWidget);
    expect(
      find.text('Community summary — never shown in the header.'),
      findsNothing,
    );

    // Screenshots: community first with captions, then backend extras
    // deduped by URL. The mock HTTP client fails every image load, so
    // each tile also shows the honest broken-image icon.
    expect(find.text('Start page'), findsOneWidget);
    expect(find.text('Shared shot'), findsOneWidget);
    expect(
      imageUrls(tester),
      [
        'https://example.com/c1.png',
        'https://example.com/shared.png',
        'https://backend.example/shot-b1.png',
      ],
    );
    expect(find.byIcon(YaruIcons.image_missing), findsNWidgets(3));

    // Community permissions block: labeled, after the install button —
    // never in the ADR-009 position. The backend permission list is
    // still first.
    expect(
      find.text(tester.l10n.communityMetadataPermissionsLabel),
      findsOneWidget,
    );
    expect(find.text('Sandboxing: Sandboxed'), findsOneWidget);
    expect(find.text('network'), findsOneWidget);
    expect(find.text('home.read'), findsOneWidget);
    final backendPermissionsDy = tester
        .getTopLeft(find.text('Network access').first)
        .dy;
    final installDy = tester
        .getTopLeft(find.text(tester.l10n.snapActionInstallLabel).first)
        .dy;
    final communityPermissionsDy = tester
        .getTopLeft(
          find.text(tester.l10n.communityMetadataPermissionsLabel),
        )
        .dy;
    expect(backendPermissionsDy, lessThan(installDy));
    expect(installDy, lessThan(communityPermissionsDy));
    // Trust copy: the live backend list wins for trust decisions.
    expect(
      find.text(tester.l10n.communityMetadataPermissionsNote),
      findsOneWidget,
    );

    // Rating with count, labeled by source.
    expect(find.text('4.3 · 128 community ratings'), findsOneWidget);
  });

  testWidgets('backend description shown when the community has none', (
    tester,
  ) async {
    final metadata = CommunityAppMetadata.fromJson({
      'canonicalId': 'appstream:org.test.app',
      'rating': {'mean': 4.0, 'count': 10},
    });
    await pumpMetadataDetails(tester, metadata: metadata);
    await tester.pumpAndSettle();

    // No community description → backend description, no tag.
    expect(
      find.text('Backend description of the test app.'),
      findsOneWidget,
    );
    expect(
      find.text(tester.l10n.communityMetadataCuratedTag),
      findsNothing,
    );
    // The present rating still renders.
    expect(find.text('4.0 · 10 community ratings'), findsOneWidget);
    // …and the absent permissions block renders nothing (no empty
    // state).
    expect(
      find.text(tester.l10n.communityMetadataPermissionsLabel),
      findsNothing,
    );
  });

  testWidgets('missing metadata: today\'s page bit-for-bit', (tester) async {
    await pumpMetadataDetails(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('Backend description of the test app.'),
      findsOneWidget,
    );
    // No community strings anywhere — the section is absent, not
    // empty.
    expect(
      find.text(tester.l10n.communityMetadataCuratedTag),
      findsNothing,
    );
    expect(
      find.text(tester.l10n.communityMetadataPermissionsLabel),
      findsNothing,
    );
    expect(find.text('community ratings'), findsNothing);
    // Backend data intact: ADR-009 permissions and backend screenshots
    // only.
    expect(find.text('Network access'), findsWidgets);
    expect(
      imageUrls(tester),
      [
        'https://backend.example/shot-b1.png',
        'https://example.com/shared.png',
      ],
    );
  });

  testWidgets('flag off with metadata present: page unchanged', (
    tester,
  ) async {
    await pumpMetadataDetails(
      tester,
      metadata: communityMetadata(),
      metadataFlag: false,
    );
    await tester.pumpAndSettle();

    // The provider returns null before the cache when the flag is off —
    // the page never sees the metadata.
    expect(
      find.text('Backend description of the test app.'),
      findsOneWidget,
    );
    expect(
      find.text(tester.l10n.communityMetadataCuratedTag),
      findsNothing,
    );
    expect(
      find.text(tester.l10n.communityMetadataPermissionsLabel),
      findsNothing,
    );
    expect(find.text('4.3 · 128 community ratings'), findsNothing);
  });

  testWidgets('variant picker unchanged; community block renders once', (
    tester,
  ) async {
    const debIdentity = AppIdentity(backendId: 'deb', nativeId: 'test-deb');
    final app = UnifiedApp(
      groupId: 'appstream:org.test.app',
      canonicalId: canonicalId,
      variants: const [
        AppInfo(
          identity: snapIdentity,
          name: 'Test App',
          summary: 'backend summary',
          iconUrl: '',
          source: AppSource.snap,
          version: '1.0',
        ),
        AppInfo(
          identity: debIdentity,
          name: 'test-deb',
          summary: 'a test deb',
          iconUrl: '',
          source: AppSource.deb,
          version: '2.0',
        ),
      ],
    );

    await pumpMetadataDetails(
      tester,
      metadata: communityMetadata(),
      app: app,
    );
    await tester.pumpAndSettle();

    // Merged picker chips keep today's content (badge + version).
    expect(find.text('1.0'), findsOneWidget);
    expect(find.text('2.0'), findsOneWidget);
    // The format-agnostic community block renders once, under the
    // switcher — not once per variant.
    expect(
      find.text('Community description of the test app.'),
      findsOneWidget,
    );
    expect(
      find.text(tester.l10n.communityMetadataPermissionsLabel),
      findsOneWidget,
    );

    await tester.tap(find.text('Deb'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // Switching variants keeps one community block on the deb card.
    expect(find.text('test-deb'), findsOneWidget);
    expect(
      find.text('Community description of the test app.'),
      findsOneWidget,
    );
    expect(
      find.text(tester.l10n.communityMetadataPermissionsLabel),
      findsOneWidget,
    );
  });
}

/// Test double for the slice-5 host seam: serves canned backend details
/// and a fixed community metadata entry (or none). Everything else is
/// the real [StoreHost].
class _MetadataHost extends StoreHost {
  _MetadataHost({this.metadata}) : super(flags: MapFeatureFlags());

  final CommunityAppMetadata? metadata;

  @override
  Future<AppDetails> getDetails(AppIdentity app) async {
    return AppDetails(
      app: AppInfo(
        identity: app,
        name: app.nativeId == 'test-deb' ? 'test-deb' : 'Test App',
        summary: 'backend summary',
        iconUrl: '',
        source: AppSource.snap,
      ),
      description: 'Backend description of the test app.',
      screenshots: const [
        'https://backend.example/shot-b1.png',
        'https://example.com/shared.png',
      ],
      permissions: const [Permission(id: 'network', label: 'Network access')],
    );
  }

  @override
  Future<CommunityAppMetadata?> getCommunityMetadata(
    CanonicalAppId id,
  ) async => metadata;
}
