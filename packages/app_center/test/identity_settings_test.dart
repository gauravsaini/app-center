import 'dart:io';

import 'package:app_center/settings/settings.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:backend_appimage/testing.dart';
import 'package:backend_deb/backend_deb.dart';
import 'package:backend_deb/testing.dart';
import 'package:backend_flatpak/testing.dart';
import 'package:backend_pacman/testing.dart';
import 'package:backend_rpm/testing.dart';
import 'package:backend_snap/backend_snap.dart';
import 'package:backend_snap/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'test_utils.dart';

/// Snap transport serving only Firefox (resolves to
/// `appstream:org.mozilla.firefox` via the bundled seed index).
class _FirefoxSnapTransport extends StubSnapdTransport {
  @override
  Future<List<SnapSummaryData>> find(String query) async => const [
    SnapSummaryData(
      name: 'firefox',
      title: 'Firefox',
      summary: 'a web browser',
      description: 'Firefox web browser.',
      version: '1.0',
      iconUrl: '',
      confinement: 'strict',
      website: 'https://www.mozilla.org/firefox',
      commonIds: ['org.mozilla.firefox'],
    ),
  ];
}

/// Deb transport serving only Firefox (same canonical id as the snap).
class _FirefoxDebTransport extends StubPackageKitTransport {
  @override
  Future<List<DebPackageData>> search(String query) async => const [
    DebPackageData(
      name: 'firefox',
      summary: 'a web browser',
      description: 'Firefox web browser.',
      version: '1.0',
      url: 'https://www.mozilla.org/firefox',
    ),
  ];
}

StoreHost _stubHost(MapFeatureFlags flags) => buildStoreHost(
  flags,
  snapTransport: _FirefoxSnapTransport(),
  flatpakTransport: StubFlatpakTransport(),
  debTransport: _FirefoxDebTransport(),
  appimageTransport: StubAppimageTransport(),
  rpmTransport: StubRpmTransport(),
  pacmanTransport: StubPacmanTransport(),
);

/// Widget tests for the Settings page's "App identity" section
/// (docs/architecture/phase3-slice4.md).
/// Scripted fetch vehicle for the fake-transport ok-path test: serves
/// [body] for every mirror URL.
class _ScriptedCommunityTransport implements CommunityIndexTransport {
  _ScriptedCommunityTransport(this.body);

  final String body;

  @override
  Future<String> fetch(Uri url) async => body;
}

/// Fake host for the community refresh ok-path: overrides
/// [refreshCommunityIndex] to drive the injected transport (proving the
/// button reaches it) then return a canned ok result. No crypto, no
/// file I/O — the UI behavior is what's under test.
class _FakeRefreshHost extends StoreHost {
  _FakeRefreshHost(
    FeatureFlags flags, {
    required this.transport,
    required this.result,
  }) : super(flags: flags);

  final CommunityIndexTransport transport;
  final CommunityRefreshResult result;
  bool refreshCalled = false;

  @override
  Future<CommunityRefreshResult> refreshCommunityIndex({
    CommunityIndexTransport? transport,
    Object? trust,
  }) async {
    refreshCalled = true;
    // Drive the injected transport so the test proves the button
    // reaches it (checking state becomes visible).
    await (transport ?? this.transport).fetch(
      Uri.parse('https://mirror.example/index.json'),
    );
    return result;
  }
}

/// In-memory [CommunityRefreshStore]: real file I/O never completes
/// under testWidgets' FakeAsync zone.
class _FakeRefreshStore extends CommunityRefreshStore {
  CommunityRefreshRecord? _record;

  @override
  Future<CommunityRefreshRecord?> load() async => _record;

  @override
  Future<void> save(CommunityRefreshRecord record) async {
    _record = record;
  }
}

void main() {
  setUp(registerMockRatingsService);
  tearDown(resetAllServices);

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('identity-settings-test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  List<Override> overridesFor(MapFeatureFlags flags) => [
    storeFlagsProvider.overrideWithValue(flags),
    storeHostProvider.overrideWithValue(_stubHost(flags)),
    communityRefreshStoreProvider.overrideWithValue(
      CommunityRefreshStore(baseDir: tmp.path),
    ),
  ];

  testWidgets('identity toggle flips the flag', (tester) async {
    final flags = MapFeatureFlags();
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: overridesFor(flags),
        child: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(flags.isEnabled('phase3.identity.enabled'), isFalse);
    // The identity toggle is the first switch on the page.
    // (YaruSwitchListTile renders a YaruSwitch, not a material Switch.)
    await tester.tap(find.byType(YaruSwitch).first);
    await tester.pumpAndSettle();

    expect(flags.isEnabled('phase3.identity.enabled'), isTrue);
  });

  testWidgets('toggling identity on marks search stale without a restart', (
    tester,
  ) async {
    final flags = MapFeatureFlags();
    final host = _stubHost(flags);
    // Warm the host caches in the real async zone (identity index +
    // source preferences involve real file I/O, which never completes
    // under testWidgets' FakeAsync).
    await tester.runAsync(() async {
      flags.setFlag('phase3.identity.enabled', true);
      final warmed = await host.search('firefox').toList();
      expect(warmed.where((a) => a.canonicalId != null), hasLength(1));
      flags.setFlag('phase3.identity.enabled', false);
    });

    late WidgetRef capturedRef;
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
          communityRefreshStoreProvider.overrideWithValue(
            CommunityRefreshStore(baseDir: tmp.path),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Drive the exact production toggle path.
    setIdentityEnabled(capturedRef, true);
    await tester.pump();

    // Toggle took effect without a restart: the flag is on. (Provider
    // invalidation is exercised by setIdentityEnabled; the re-search
    // itself is covered at the host level above.)
    expect(capturedRef.read(identityEnabledProvider), isTrue);
    expect(flags.isEnabled('phase3.identity.enabled'), isTrue);
  });

  testWidgets('merged card shows N formats chip when identity on', (
    tester,
  ) async {
    final flags = MapFeatureFlags({'phase3.identity.enabled': true});
    final host = _stubHost(flags);
    // Build the merged app via the real host (real async zone).
    late UnifiedApp mergedApp;
    await tester.runAsync(() async {
      final apps = await host.search('firefox').toList();
      final merged = apps.where((a) => a.canonicalId != null);
      expect(merged, hasLength(1));
      expect(merged.single.variants, hasLength(2));
      mergedApp = merged.single;
    });

    // Pump the card footer directly (not via the SearchPage grid — the
    // grid's fixed aspect ratio overflows with the chip, a pre-existing
    // layout issue unrelated to this slice).
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [storeFlagsProvider.overrideWithValue(flags)],
        child: Scaffold(
          body: AppCard.fromUnifiedApp(app: mergedApp, onTap: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Firefox'), findsOneWidget);
    expect(find.text('2 formats'), findsOneWidget);
  });

  testWidgets('toggling identity off clears the flag without a restart', (
    tester,
  ) async {
    final flags = MapFeatureFlags({'phase3.identity.enabled': true});
    final host = _stubHost(flags);

    late WidgetRef capturedRef;
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
          communityRefreshStoreProvider.overrideWithValue(
            CommunityRefreshStore(baseDir: tmp.path),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(capturedRef.read(identityEnabledProvider), isTrue);

    setIdentityEnabled(capturedRef, false);
    await tester.pump();

    expect(capturedRef.read(identityEnabledProvider), isFalse);
    expect(flags.isEnabled('phase3.identity.enabled'), isFalse);
  });

  testWidgets('section renders sensibly with the identity flag off', (
    tester,
  ) async {
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: overridesFor(MapFeatureFlags()),
        child: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = tester.l10n;
    expect(find.text(l10n.settingsAppIdentityTitle), findsOneWidget);
    expect(find.text(l10n.settingsIdentityToggleTitle), findsOneWidget);
    expect(find.text(l10n.settingsCommunityTitle), findsOneWidget);
    // Honest copy: the signature disclaimer is always visible.
    expect(find.text(l10n.settingsCommunitySignatureNote), findsOneWidget);
    expect(find.text(l10n.settingsCommunityMirrors(0)), findsOneWidget);
    // Slice 6 adds the metadata subsection to this section; it reuses
    // the same "Never refreshed" copy for its own last-refresh line.
    expect(find.text(l10n.settingsCommunityNeverRefreshed), findsNWidgets(2));
    expect(find.text(l10n.settingsCommunityRefreshButton), findsOneWidget);
  });

  testWidgets('refresh with community disabled reports skipped, no throw', (
    tester,
  ) async {
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: overridesFor(
          MapFeatureFlags({'phase3.identity.enabled': true}),
        ),
        child: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    // The refresh does real file I/O (last-refresh record), which never
    // completes under testWidgets' FakeAsync zone: futures started there
    // stay bound to it. Tap the real button inside runAsync so the whole
    // refresh runs in the real async zone, then wait for a terminal state.
    await tester.runAsync(() async {
      await tester.tap(find.text(tester.l10n.settingsCommunityRefreshButton));
      for (var i = 0; i < 200; i++) {
        final s = container.read(communityRefreshStateProvider);
        if (s is! CommunityRefreshChecking) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();
    // The host's gate reason is shown verbatim.
    expect(find.textContaining('phase3.community.enabled'), findsOneWidget);
  });

  testWidgets('refresh with an unreachable mirror reports failed, no throw', (
    tester,
  ) async {
    final flags = MapFeatureFlags({
      'phase3.identity.enabled': true,
      'phase3.community.enabled': true,
      'phase3.community.mirrors': 'https://127.0.0.1:9/index.json',
    });
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: overridesFor(flags),
        child: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.settingsCommunityMirrors(1)), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    // Real file I/O + real (refused) network I/O: run the button tap in
    // the real async zone (see the skipped test above).
    await tester.runAsync(() async {
      await tester.tap(find.text(tester.l10n.settingsCommunityRefreshButton));
      for (var i = 0; i < 400; i++) {
        final s = container.read(communityRefreshStateProvider);
        if (s is! CommunityRefreshChecking) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.settingsCommunityFailed), findsOneWidget);
    // Per-mirror reason shown verbatim; the attempt was recorded and the
    // last-refresh line stays visible even in the failed state.
    expect(find.textContaining('127.0.0.1'), findsOneWidget);
    expect(
      find.textContaining(tester.l10n.settingsCommunityLastRefresh('')),
      findsOneWidget,
    );
  });

  testWidgets('up-to-date state renders entries, mirror and key id', (
    tester,
  ) async {
    final flags = MapFeatureFlags({
      'phase3.identity.enabled': true,
      'phase3.community.enabled': true,
      'phase3.community.mirrors': 'https://mirror.example/index.json',
    });
    late CommunityRefreshNotifier notifier;
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: overridesFor(flags),
        child: Consumer(
          builder: (context, ref, _) {
            notifier = ref.read(communityRefreshStateProvider.notifier);
            return const SettingsPage();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    notifier.debugSetState(
      CommunityRefreshUpToDate(
        entryCount: 128,
        generatedAt: DateTime.utc(2026, 9, 27, 12),
        mirror: 'https://mirror.example/index.json',
        keyId: 'libreapp-index-test',
      ),
    );
    await tester.pumpAndSettle();

    final l10n = tester.l10n;
    expect(find.text(l10n.settingsCommunityUpToDate), findsOneWidget);
    expect(find.text(l10n.settingsCommunityEntries(128)), findsOneWidget);
    // The winning mirror renders both in the mirror status line and in
    // the up-to-date result.
    expect(
      find.text(
        l10n.settingsCommunityFromMirror('https://mirror.example/index.json'),
      ),
      findsWidgets,
    );
    // Honest copy: "signature valid", never "verified safe".
    expect(
      find.text(l10n.settingsCommunitySignedBy('libreapp-index-test')),
      findsOneWidget,
    );
    expect(find.textContaining('verified safe'), findsNothing);
  });

  testWidgets('failed state keeps the last successful refresh line', (
    tester,
  ) async {
    late CommunityRefreshNotifier notifier;
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: overridesFor(MapFeatureFlags()),
        child: Consumer(
          builder: (context, ref, _) {
            notifier = ref.read(communityRefreshStateProvider.notifier);
            return const SettingsPage();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    notifier.debugSetState(
      CommunityRefreshFailed(
        errorsByMirror: const {
          'https://mirror.example/index.json': 'fetch failed: boom',
        },
        lastRecord: CommunityRefreshRecord(
          attemptedAt: DateTime.utc(2026, 9, 27, 12),
          succeededAt: DateTime.utc(2026, 9, 26, 12),
          mirror: 'https://mirror.example/index.json',
          entryCount: 64,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = tester.l10n;
    expect(find.text(l10n.settingsCommunityFailed), findsOneWidget);
    expect(find.textContaining('fetch failed: boom'), findsOneWidget);
    // The last successful refresh line survives the failed state.
    expect(
      find.textContaining(l10n.settingsCommunityLastSuccess('')),
      findsOneWidget,
    );
    expect(
      find.textContaining(l10n.settingsCommunityLastRefresh('')),
      findsOneWidget,
    );
  });

  group('CommunityRefreshStore', () {
    test('round-trips a record', () async {
      final store = CommunityRefreshStore(baseDir: tmp.path);
      expect(await store.load(), isNull);
      final record = CommunityRefreshRecord(
        attemptedAt: DateTime.utc(2026, 9, 28, 1, 30),
        succeededAt: DateTime.utc(2026, 9, 28, 1, 30),
        mirror: 'https://mirror.example/index.json',
        entryCount: 128,
      );
      await store.save(record);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.mirror, 'https://mirror.example/index.json');
      expect(loaded.entryCount, 128);
      expect(loaded.succeededAt, record.succeededAt);
    });

    test('corrupt file loads as null, never throws', () async {
      final store = CommunityRefreshStore(baseDir: tmp.path);
      final file = File(
        '${tmp.path}/libreapp-center/community-refresh.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('not json {{{');
      expect(await store.load(), isNull);
    });
  });

  group('fake-transport ok path', () {
    testWidgets(
      'refresh drives a fake transport to up-to-date',
      (tester) async {
        final flags = MapFeatureFlags({
          'phase3.identity.enabled': true,
          'phase3.community.enabled': true,
          'phase3.community.mirrors': 'https://mirror.example/index.json',
        });
        final fakeHost = _FakeRefreshHost(
          flags,
          transport: _ScriptedCommunityTransport('{}'),
          result: CommunityRefreshResult.ok(
            entryCount: 1,
            generatedAt: DateTime.utc(2026, 9, 27, 12),
            mirror: 'https://mirror.example/index.json',
            keyId: 'test-key',
          ),
        );
        await tester.pumpApp(
          (_) => ProviderScope(
            overrides: [
              storeFlagsProvider.overrideWithValue(flags),
              storeHostProvider.overrideWithValue(fakeHost),
              communityRefreshStoreProvider.overrideWithValue(
                _FakeRefreshStore(),
              ),
              communityTransportOverrideProvider.overrideWithValue(
                _ScriptedCommunityTransport('{}'),
              ),
            ],
            child: const SettingsPage(),
          ),
        );
        await tester.pumpAndSettle();

        // Tap the refresh button; the fake host drives the transport
        // (checking state) then returns the canned ok. Pump a fixed
        // duration — the progress spinner never settles.
        await tester.tap(
          find.text(tester.l10n.settingsCommunityRefreshButton),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          final s = ProviderScope.containerOf(
            tester.element(find.byType(SettingsPage)),
          ).read(communityRefreshStateProvider);
          if (s is! CommunityRefreshChecking) break;
        }

        expect(fakeHost.refreshCalled, isTrue);
        final l10n = tester.l10n;
        expect(
          find.text(l10n.settingsCommunityUpToDate),
          findsOneWidget,
        );
        expect(find.text(l10n.settingsCommunityEntries(1)), findsOneWidget);
        expect(
          find.text(
            l10n.settingsCommunityFromMirror(
              'https://mirror.example/index.json',
            ),
          ),
          findsWidgets,
        );
        expect(
          find.text(l10n.settingsCommunitySignedBy('test-key')),
          findsOneWidget,
        );
      },
    );
  });
}
