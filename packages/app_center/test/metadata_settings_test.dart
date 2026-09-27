/// Widget + unit tests for the Settings page's "Community metadata"
/// subsection (docs/architecture/phase3-slice6.md).
///
/// Mirrors `identity_settings_test.dart` as the model:
///
/// - the metadata toggle flips `phase3.metadata.enabled` and the
///   details page shows/hides community sections without a restart
///   (provider invalidation, not host rebuild)
/// - the refresh button drives a fake transport through the REAL host
///   with an ephemeral trust store (never the placeholder bootstrap
///   key): ok → up-to-date, tampered doc → failed, gates off → skipped
/// - the last-refresh record persists across a failed attempt
/// - no live network anywhere; all docs are signed in-test with
///   ephemeral Ed25519 keypairs
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:app_center/details/details.dart';
import 'package:app_center/settings/settings.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_service/ubuntu_service.dart';
import 'package:yaru/yaru.dart';

import 'test_utils.dart';

const _metadataMirror = 'https://mirror.example/metadata.json';

/// Scripted fetch vehicle for the real-host refresh tests: serves
/// [body] (mutable, so one pump can do ok-then-failed) for every
/// mirror URL.
class _ScriptedMetadataTransport implements CommunityIndexTransport {
  _ScriptedMetadataTransport(this.body);

  String body;

  @override
  Future<String> fetch(Uri url) async => body;
}

/// Generates an ephemeral Ed25519 keypair and the trust store pinning
/// it under [keyId]. The placeholder bootstrap key is never used.
Future<({CommunityTrustStore trust, SimpleKeyPair keyPair, String keyId})>
ephemeralMetadataTrust({String keyId = 'metadata-test-key'}) async {
  final keyPair = await Ed25519().newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return (
    trust: CommunityTrustStore({keyId: base64.encode(publicKey.bytes)}),
    keyPair: keyPair,
    keyId: keyId,
  );
}

/// Test-local canonical JSON encoder — mirrors the host's sorted-key
/// encoding so the test signs exactly the bytes the host verifies,
/// without importing package internals.
Uint8List canonicalJsonBytes(Map<String, Object?> doc) {
  final sb = StringBuffer();
  _writeCanonical(sb, doc);
  return Uint8List.fromList(utf8.encode(sb.toString()));
}

void _writeCanonical(StringBuffer sb, Object? value) {
  switch (value) {
    case null:
      sb.write('null');
    case true:
      sb.write('true');
    case false:
      sb.write('false');
    case final String s:
      _writeEscapedString(sb, s);
    case final num n:
      sb.write(jsonEncode(n));
    case final List<Object?> l:
      sb.write('[');
      for (var i = 0; i < l.length; i++) {
        if (i > 0) sb.write(',');
        _writeCanonical(sb, l[i]);
      }
      sb.write(']');
    case final Map<String, Object?> m:
      // Sort keys by code-unit order, recursively — exactly like the
      // host.
      final keys = m.keys.toList()..sort();
      sb.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) sb.write(',');
        _writeEscapedString(sb, keys[i]);
        sb.write(':');
        _writeCanonical(sb, m[keys[i]]);
      }
      sb.write('}');
    default:
      throw FormatException(
        'Cannot canonicalize value of type ${value.runtimeType}',
      );
  }
}

void _writeEscapedString(StringBuffer sb, String s) {
  sb.write('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    switch (c) {
      case 0x22:
        sb.write(r'\"');
      case 0x5C:
        sb.write(r'\\');
      case 0x08:
        sb.write(r'\b');
      case 0x0C:
        sb.write(r'\f');
      case 0x0A:
        sb.write(r'\n');
      case 0x0D:
        sb.write(r'\r');
      case 0x09:
        sb.write(r'\t');
      default:
        if (c < 0x20) {
          sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          sb.writeCharCode(c);
        }
    }
  }
  sb.write('"');
}

/// Builds a signed `community-metadata` doc body for [records]
/// (signature envelope added by real Ed25519 over the canonical JSON
/// bytes — the same bytes the host verifies).
Future<String> signedMetadataBody({
  required List<Map<String, Object?>> records,
  required SimpleKeyPair keyPair,
  required String keyId,
}) async {
  final body = <String, Object?>{
    'schemaVersion': 1,
    'docType': 'community-metadata',
    'generatedAt': '2026-09-28T03:00:00Z',
    'source': 'community',
    'metadata': records,
  };
  final message = canonicalJsonBytes(body);
  final signature = await Ed25519().sign(message, keyPair: keyPair);
  body['signature'] = <String, Object?>{
    'keyId': keyId,
    'algorithm': 'ed25519',
    'sig': base64.encode(signature.bytes),
  };
  return jsonEncode(body);
}

/// Flips one base64 character of the signature: the doc is otherwise
/// byte-identical, so verification must fail (tamper rejection).
/// Note: the body is compact `jsonEncode` output (`"sig":"…"`, no
/// spaces), which the pattern matches.
String tamperSignature(String signedBody) =>
    signedBody.replaceFirstMapped(RegExp('"sig":"([A-Za-z0-9])'), (m) {
      final c = m[1]!;
      return '"sig":"${c == 'A' ? 'B' : 'A'}';
    });

/// A real [StoreHost] rooted at a fake HOME (injected environment), so
/// refresh tests never touch the real
/// `~/.local/share/libreapp-center/`. No backends registered — the
/// metadata refresh path never touches a backend.
StoreHost realMetadataHost(MapFeatureFlags flags, String home) =>
    StoreHost(flags: flags, environment: {'HOME': home});

/// Test double for the toggle tests: serves canned backend details and
/// a mutable community metadata entry. Everything else is the real
/// [StoreHost].
class _FakeMetadataHost extends StoreHost {
  _FakeMetadataHost({this.metadata}) : super(flags: MapFeatureFlags());

  CommunityAppMetadata? metadata;

  @override
  Future<AppDetails> getDetails(AppIdentity app) async => AppDetails(
    app: AppInfo(
      identity: app,
      name: 'Test App',
      summary: 'backend summary',
      iconUrl: '',
      source: AppSource.snap,
    ),
    description: 'Backend description of the test app.',
  );

  @override
  Future<CommunityAppMetadata?> getCommunityMetadata(
    CanonicalAppId id,
  ) async => metadata;
}

CommunityAppMetadata metadataFixture(String description) =>
    CommunityAppMetadata.fromJson({
      'canonicalId': 'appstream:org.test.app',
      'description': description,
      'rating': {'mean': 4.3, 'count': 128},
    });

void main() {
  setUp(registerMockRatingsService);
  tearDown(resetAllServices);

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('metadata-settings-test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  const canonicalId = CanonicalAppId(
    CanonicalIdScheme.appstream,
    'org.test.app',
  );
  const snapIdentity = AppIdentity(backendId: 'snap', nativeId: 'test-snap');

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

  MapFeatureFlags metadataFlags() => MapFeatureFlags({
    'phase3.identity.enabled': true,
    'phase3.metadata.enabled': true,
    'phase3.community.enabled': true,
    'phase3.community.metadata.mirrors': _metadataMirror,
  });

  /// Pumps the details page against the fake metadata host. The caller
  /// captures the [WidgetRef] to drive the production toggle paths.
  Future<WidgetRef> pumpMetadataDetails(
    WidgetTester tester, {
    required _FakeMetadataHost host,
    required MapFeatureFlags flags,
  }) async {
    late WidgetRef capturedRef;
    await tester.pumpApp(
      (_) => ProviderScope(
        overrides: [
          storeFlagsProvider.overrideWithValue(flags),
          storeHostProvider.overrideWithValue(host),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return UnifiedDetailsPage(
              identity: snapIdentity,
              app: singleVariantApp(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return capturedRef;
  }

  /// The settings page is a CustomScrollView and the metadata
  /// subsection sits below the fold at pumpApp's 854x654 viewport —
  /// grow the test window tall (after pumpApp, which pins the size)
  /// so every control is on-screen and tappable.
  Future<void> pumpSettingsPage(
    WidgetTester tester,
    List<Override> overrides,
  ) async {
    await tester.pumpApp(
      (_) => ProviderScope(overrides: overrides, child: const SettingsPage()),
    );
    // physicalSize is in physical pixels — scale the tall logical
    // window by the view's devicePixelRatio.
    tester.view.physicalSize =
        const Size(900, 1600) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
  }

  /// Taps the metadata "Refresh metadata" button and waits (in the
  /// real async zone — real file I/O never completes under
  /// testWidgets' FakeAsync) until the refresh reaches a terminal
  /// state.
  Future<void> tapMetadataRefresh(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(
        find.text(tester.l10n.settingsMetadataRefreshButton),
      );
      for (var i = 0; i < 400; i++) {
        final s = container.read(communityMetadataRefreshStateProvider);
        if (s is! CommunityMetadataRefreshChecking) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    // Fail fast with the stuck state instead of hanging pumpAndSettle
    // on the checking spinner.
    final state = container.read(communityMetadataRefreshStateProvider);
    expect(
      state,
      isNot(isA<CommunityMetadataRefreshChecking>()),
      reason: 'metadata refresh never left the checking state',
    );
    await tester.pumpAndSettle();
  }

  ProviderContainer containerOfSettings(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(SettingsPage)));

  testWidgets('metadata toggle flips the flag', (tester) async {
    final flags = MapFeatureFlags();
    await pumpSettingsPage(tester, [
      storeFlagsProvider.overrideWithValue(flags),
      storeHostProvider.overrideWithValue(realMetadataHost(flags, tmp.path)),
      communityMetadataRefreshStoreProvider.overrideWithValue(
        CommunityMetadataRefreshStore(baseDir: tmp.path),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(flags.isEnabled('phase3.metadata.enabled'), isFalse);
    // The metadata toggle is the switch inside the tile titled
    // "Enable community metadata" (the third switch on the page).
    // Tap the tile (not the switch itself): the tile owns the tap
    // target, and the tall test viewport keeps it on-screen.
    final tile = find.widgetWithText(
      YaruSwitchListTile,
      tester.l10n.settingsMetadataToggleTitle,
    );
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(flags.isEnabled('phase3.metadata.enabled'), isTrue);
  });

  testWidgets(
    'metadata toggle shows/hides community sections without a restart',
    (tester) async {
      final flags = MapFeatureFlags({
        'phase3.identity.enabled': true,
        'phase3.metadata.enabled': true,
      });
      final host = _FakeMetadataHost(
        metadata: metadataFixture('Community description A.'),
      );
      final ref = await pumpMetadataDetails(
        tester,
        host: host,
        flags: flags,
      );

      final l10n = tester.l10n;
      expect(find.text('Community description A.'), findsOneWidget);
      expect(find.text(l10n.communityMetadataCuratedTag), findsOneWidget);

      // Toggle off: community sections disappear without a restart.
      setMetadataEnabled(ref, false);
      await tester.pumpAndSettle();
      expect(find.text('Community description A.'), findsNothing);
      expect(find.text(l10n.communityMetadataCuratedTag), findsNothing);

      // Toggle on again: sections reappear without a restart.
      setMetadataEnabled(ref, true);
      await tester.pumpAndSettle();
      expect(find.text('Community description A.'), findsOneWidget);
      expect(find.text(l10n.communityMetadataCuratedTag), findsOneWidget);
    },
  );

  testWidgets('toggling metadata on re-reads the provider, no stale cache', (
    tester,
  ) async {
    final flags = MapFeatureFlags({
      'phase3.identity.enabled': true,
      'phase3.metadata.enabled': true,
    });
    final host = _FakeMetadataHost(
      metadata: metadataFixture('Community description A.'),
    );
    final ref = await pumpMetadataDetails(tester, host: host, flags: flags);
    expect(find.text('Community description A.'), findsOneWidget);

    // While the toggle is off, the upstream metadata changes. Toggling
    // back on must invalidate the cached family entry and re-read —
    // showing B, not the stale A.
    setMetadataEnabled(ref, false);
    await tester.pumpAndSettle();
    host.metadata = metadataFixture('Community description B.');
    setMetadataEnabled(ref, true);
    await tester.pumpAndSettle();

    expect(find.text('Community description A.'), findsNothing);
    expect(find.text('Community description B.'), findsOneWidget);
  });

  testWidgets('toggling identity off hides the metadata sections', (
    tester,
  ) async {
    final flags = MapFeatureFlags({
      'phase3.identity.enabled': true,
      'phase3.metadata.enabled': true,
    });
    final host = _FakeMetadataHost(
      metadata: metadataFixture('Community description A.'),
    );
    final ref = await pumpMetadataDetails(tester, host: host, flags: flags);
    expect(find.text('Community description A.'), findsOneWidget);

    // Identity gates metadata (phase3-slice5.md §4): flipping identity
    // off must drop the cached metadata lookups too.
    setIdentityEnabled(ref, false);
    await tester.pumpAndSettle();
    expect(find.text('Community description A.'), findsNothing);
    expect(
      find.text(tester.l10n.communityMetadataCuratedTag),
      findsNothing,
    );
  });

  testWidgets('section renders sensibly with the metadata flag off', (
    tester,
  ) async {
    final flags = MapFeatureFlags();
    await pumpSettingsPage(tester, [
      storeFlagsProvider.overrideWithValue(flags),
      storeHostProvider.overrideWithValue(realMetadataHost(flags, tmp.path)),
      communityMetadataRefreshStoreProvider.overrideWithValue(
        CommunityMetadataRefreshStore(baseDir: tmp.path),
      ),
    ]);
    await tester.pumpAndSettle();

    final l10n = tester.l10n;
    expect(find.text(l10n.settingsMetadataTitle), findsOneWidget);
    expect(find.text(l10n.settingsMetadataDescription), findsOneWidget);
    // Honest copy: the signature disclaimer is always visible.
    expect(find.text(l10n.settingsMetadataSignatureNote), findsOneWidget);
    expect(find.text(l10n.settingsMetadataToggleTitle), findsOneWidget);
    expect(find.text(l10n.settingsMetadataMirrors(0)), findsOneWidget);
    // Shared with the identity-index section above, which also shows
    // it — one per section.
    expect(find.text(l10n.settingsCommunityNeverRefreshed), findsNWidgets(2));
    expect(find.text(l10n.settingsMetadataRefreshButton), findsOneWidget);
  });

  group('real-host metadata refresh', () {
    /// Pumps the Settings page against the REAL host (fake HOME), with
    /// the fake transport + ephemeral trust overrides.
    Future<
      (
        ProviderContainer,
        _ScriptedMetadataTransport,
      )
    >
    pumpRealRefresh(
      WidgetTester tester, {
      required MapFeatureFlags flags,
      required String body,
      required CommunityTrustStore trust,
    }) async {
      final transport = _ScriptedMetadataTransport(body);
      await pumpSettingsPage(tester, [
        storeFlagsProvider.overrideWithValue(flags),
        storeHostProvider.overrideWithValue(
          realMetadataHost(flags, tmp.path),
        ),
        communityMetadataRefreshStoreProvider.overrideWithValue(
          CommunityMetadataRefreshStore(baseDir: tmp.path),
        ),
        metadataTransportOverrideProvider.overrideWithValue(transport),
        metadataTrustOverrideProvider.overrideWithValue(trust),
      ]);
      await tester.pumpAndSettle();
      return (containerOfSettings(tester), transport);
    }

    Future<String> twoRecordBody(
      ({
        CommunityTrustStore trust,
        SimpleKeyPair keyPair,
        String keyId,
      })
      signer,
    ) => signedMetadataBody(
      records: [
        {
          'canonicalId': 'appstream:org.test.one',
          'description': 'First test app.',
        },
        {
          'canonicalId': 'appstream:org.test.two',
          'description': 'Second test app.',
        },
      ],
      keyPair: signer.keyPair,
      keyId: signer.keyId,
    );

    testWidgets('refresh drives a fake transport to up-to-date', (
      tester,
    ) async {
      final trust = await ephemeralMetadataTrust();
      final body = await twoRecordBody(trust);
      final (container, _) = await pumpRealRefresh(
        tester,
        flags: metadataFlags(),
        body: body,
        trust: trust.trust,
      );

      await tapMetadataRefresh(tester, container);

      final l10n = tester.l10n;
      expect(find.text(l10n.settingsMetadataUpToDate), findsOneWidget);
      expect(find.text(l10n.settingsMetadataEntries(2)), findsOneWidget);
      // The winning mirror renders both in the mirror status line and
      // in the up-to-date result.
      expect(
        find.text(l10n.settingsCommunityFromMirror(_metadataMirror)),
        findsWidgets,
      );
      // Honest copy: "signature valid", never "verified safe".
      expect(
        find.text(l10n.settingsCommunitySignedBy('metadata-test-key')),
        findsOneWidget,
      );
      expect(find.textContaining('verified safe'), findsNothing);

      // The attempt was persisted: the winning mirror, entry count and
      // success timestamp survived the state transition. Real file
      // I/O never completes under testWidgets' FakeAsync — read in
      // the real async zone.
      final record = await tester.runAsync(
        () => container.read(communityMetadataRefreshStoreProvider).load(),
      );
      expect(record, isNotNull);
      expect(record!.mirror, _metadataMirror);
      expect(record.entryCount, 2);
      expect(record.succeededAt, isNotNull);

      // The verified doc actually landed on disk where the host reads
      // it (the refresh wasn't just UI theater).
      expect(
        File(
          '${tmp.path}/.local/share/libreapp-center/identity-metadata.json',
        ).existsSync(),
        isTrue,
      );
    });

    testWidgets('tampered metadata doc reports failed with a reason', (
      tester,
    ) async {
      final trust = await ephemeralMetadataTrust();
      final body = await twoRecordBody(trust);
      final (container, _) = await pumpRealRefresh(
        tester,
        flags: metadataFlags(),
        body: tamperSignature(body),
        trust: trust.trust,
      );

      await tapMetadataRefresh(tester, container);

      final l10n = tester.l10n;
      expect(find.text(l10n.settingsMetadataFailed), findsOneWidget);
      // Per-mirror reason shown verbatim.
      expect(find.textContaining(_metadataMirror), findsOneWidget);
      expect(find.text(l10n.settingsMetadataUpToDate), findsNothing);
    });

    testWidgets('refresh with the metadata flag off reports skipped', (
      tester,
    ) async {
      final trust = await ephemeralMetadataTrust();
      final body = await twoRecordBody(trust);
      final flags = MapFeatureFlags({
        'phase3.identity.enabled': true,
        // 'phase3.metadata.enabled' deliberately absent
        'phase3.community.enabled': true,
        'phase3.community.metadata.mirrors': _metadataMirror,
      });
      final (container, _) = await pumpRealRefresh(
        tester,
        flags: flags,
        body: body,
        trust: trust.trust,
      );

      await tapMetadataRefresh(tester, container);

      expect(find.text(tester.l10n.settingsMetadataSkipped), findsOneWidget);
      // The host's gate reason is shown verbatim.
      expect(find.textContaining('phase3.metadata.enabled'), findsOneWidget);
      expect(find.text(tester.l10n.settingsMetadataFailed), findsNothing);
    });

    testWidgets('last refresh persists across a failed attempt', (
      tester,
    ) async {
      final trust = await ephemeralMetadataTrust();
      final okBody = await twoRecordBody(trust);
      final (container, transport) = await pumpRealRefresh(
        tester,
        flags: metadataFlags(),
        body: okBody,
        trust: trust.trust,
      );
      final store = container.read(communityMetadataRefreshStoreProvider);

      await tapMetadataRefresh(tester, container);
      // Real file I/O in the real async zone (see above).
      final okRecord = await tester.runAsync(store.load);
      expect(okRecord, isNotNull);
      expect(okRecord!.succeededAt, isNotNull);

      // A tampered doc now fails — the previous success must survive.
      transport.body = tamperSignature(okBody);
      await tapMetadataRefresh(tester, container);

      expect(
        find.text(tester.l10n.settingsMetadataFailed),
        findsOneWidget,
      );
      final failedRecord = await tester.runAsync(store.load);
      expect(failedRecord, isNotNull);
      // The failed attempt was recorded (attemptedAt moved forward)…
      expect(
        failedRecord!.attemptedAt.isAfter(okRecord.attemptedAt),
        isTrue,
      );
      // …but the last success was NOT erased.
      expect(failedRecord.succeededAt, okRecord.succeededAt);
      expect(failedRecord.mirror, _metadataMirror);
      expect(failedRecord.entryCount, 2);

      // The last-success line stays visible in the failed state.
      final l10n = tester.l10n;
      expect(
        find.textContaining(l10n.settingsCommunityLastSuccess('')),
        findsOneWidget,
      );
      expect(
        find.textContaining(l10n.settingsCommunityLastRefresh('')),
        findsOneWidget,
      );
    });
  });

  group('CommunityMetadataRefreshStore', () {
    test('round-trips a record', () async {
      final store = CommunityMetadataRefreshStore(baseDir: tmp.path);
      expect(await store.load(), isNull);
      final record = CommunityMetadataRefreshRecord(
        attemptedAt: DateTime.utc(2026, 9, 28, 3, 10),
        succeededAt: DateTime.utc(2026, 9, 28, 3, 10),
        mirror: _metadataMirror,
        entryCount: 42,
      );
      await store.save(record);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.mirror, _metadataMirror);
      expect(loaded.entryCount, 42);
      expect(loaded.succeededAt, record.succeededAt);
    });

    test('corrupt file loads as null, never throws', () async {
      final store = CommunityMetadataRefreshStore(baseDir: tmp.path);
      final file = File(
        '${tmp.path}/libreapp-center/community-metadata-refresh.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('not json {{{');
      expect(await store.load(), isNull);
    });
  });

  test('metadataMirrorsProvider parses the operator mirror list', () {
    final container = createContainer(
      overrides: [
        storeFlagsProvider.overrideWithValue(
          MapFeatureFlags({
            'phase3.community.metadata.mirrors':
                'https://a.example/m.json, https://b.example/m.json ,,',
          }),
        ),
      ],
    );
    expect(container.read(metadataMirrorsProvider), [
      'https://a.example/m.json',
      'https://b.example/m.json',
    ]);
    final empty = createContainer(
      overrides: [storeFlagsProvider.overrideWithValue(MapFeatureFlags())],
    );
    expect(empty.read(metadataMirrorsProvider), isEmpty);
  });

  test('describeMetadataRefreshState names every state', () {
    expect(
      describeMetadataRefreshState(const CommunityMetadataRefreshIdle()),
      'idle',
    );
    expect(
      describeMetadataRefreshState(const CommunityMetadataRefreshChecking()),
      'checking',
    );
    expect(
      describeMetadataRefreshState(
        const CommunityMetadataRefreshUpToDate(
          entryCount: 2,
          generatedAt: null,
          mirror: null,
        ),
      ),
      'up-to-date',
    );
    expect(
      describeMetadataRefreshState(
        const CommunityMetadataRefreshFailed(errorsByMirror: {}),
      ),
      'failed',
    );
    expect(
      describeMetadataRefreshState(
        const CommunityMetadataRefreshSkipped(reason: 'x'),
      ),
      'skipped',
    );
  });
}
