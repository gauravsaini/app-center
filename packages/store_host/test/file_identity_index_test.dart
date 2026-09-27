/// [FileIdentityIndexStore] tests (phase3-identity-lld.md §7).
///
/// Forgiveness is the contract: missing and corrupt overlays are
/// skipped, never thrown. Strictness lives at the parse layer — one
/// bad entry rejects its whole doc (counted in `skippedDocs`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:store_host/src/identity/file_identity_index.dart';
import 'package:store_host/src/identity/seed_index.dart';
import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

/// One-entry overlay doc: the shape [FileIdentityIndexStore.saveOverlay]
/// writes.
String _overlayDoc(List<Map<String, Object?>> entries) =>
    jsonEncode({'schemaVersion': 1, 'source': 'test', 'entries': entries});

Map<String, Object?> _entry({
  required String canonicalId,
  String? displayName,
  List<String> appstreamIds = const [],
  List<String> homepages = const [],
  Map<String, List<String>> backends = const {},
  String provenance = 'test',
}) => {
  'canonicalId': canonicalId,
  if (displayName != null) 'displayName': displayName,
  'appstreamIds': appstreamIds,
  'homepages': homepages,
  'backends': backends,
  'provenance': {'source': provenance},
};

void main() {
  late Directory temp;
  late FileIdentityIndexStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('identity-index-test');
    store = FileIdentityIndexStore();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('load', () {
    test(
      'temp-dir overlay: new entry + override merge over the seed',
      () async {
        final overlayPath = '${temp.path}/overlay.json';
        await File(overlayPath).writeAsString(
          _overlayDoc([
            // New entry: not in the seed.
            _entry(
              canonicalId: 'appstream:org.example.NewApp',
              displayName: 'New App',
              appstreamIds: ['org.example.NewApp'],
              backends: {
                'flatpak': ['org.example.NewApp'],
              },
            ),
            // Override: firefox is already in the seed. Higher layer
            // replaces the displayName and unions the signal lists.
            _entry(
              canonicalId: 'appstream:org.mozilla.firefox',
              displayName: 'Firefox (local)',
              appstreamIds: ['org.mozilla.firefox.local'],
              backends: {
                'flatpak': ['org.mozilla.firefox.local'],
              },
            ),
          ]),
        );

        final index = await store.load(
          seedJson: kIdentitySeedJson,
          overlayPaths: [overlayPath],
        );
        expect(index.skippedDocs, 0);

        // New entry resolves.
        expect(
          index.resolve('flatpak', 'org.example.NewApp')?.toString(),
          'appstream:org.example.NewApp',
        );

        // Override: displayName replaced, signal lists unioned.
        final firefox = index.entryFor(
          const CanonicalAppId(
            CanonicalIdScheme.appstream,
            'org.mozilla.firefox',
          ),
        );
        expect(firefox, isNotNull);
        expect(firefox!.displayName, 'Firefox (local)');
        expect(
          firefox.appstreamIds,
          containsAll(['org.mozilla.firefox', 'org.mozilla.firefox.local']),
        );
        // Seed keys still resolve (union, not replace).
        expect(
          index.resolve('deb', 'firefox')?.toString(),
          'appstream:org.mozilla.firefox',
        );
        expect(
          index.resolve('flatpak', 'org.mozilla.firefox.local')?.toString(),
          'appstream:org.mozilla.firefox',
        );
      },
    );

    test('missing overlay path: seed-only index, no throw', () async {
      final index = await store.load(
        seedJson: kIdentitySeedJson,
        overlayPaths: ['${temp.path}/does-not-exist.json'],
      );
      expect(index.skippedDocs, 0);
      expect(index.entryCount, greaterThan(0));
      expect(
        index.resolve('snap', 'firefox')?.toString(),
        'appstream:org.mozilla.firefox',
      );
    });

    test('corrupt overlay file: skipped, seed still loads', () async {
      final overlayPath = '${temp.path}/corrupt.json';
      await File(overlayPath).writeAsString('{ this is not json !!!');
      final index = await store.load(
        seedJson: kIdentitySeedJson,
        overlayPaths: [overlayPath],
      );
      // The corrupt file is skipped before doc parsing, so it is not
      // counted in skippedDocs — but the seed loads regardless.
      expect(index.entryCount, greaterThan(0));
      expect(
        index.resolve('snap', 'firefox')?.toString(),
        'appstream:org.mozilla.firefox',
      );
    });

    test(
      'unparseable seed JSON: worst case is an empty index, no throw',
      () async {
        final index = await store.load(seedJson: 'definitely not json');
        expect(index.entryCount, 0);
        expect(index.resolve('snap', 'firefox'), isNull);
      },
    );

    test(
      'overlay that is valid JSON but a bad doc is skipped+counted',
      () async {
        final overlayPath = '${temp.path}/bad-doc.json';
        // schemaVersion 2: the whole doc is rejected by the parse layer.
        await File(
          overlayPath,
        ).writeAsString(jsonEncode({'schemaVersion': 2, 'entries': []}));
        final index = await store.load(
          seedJson: kIdentitySeedJson,
          overlayPaths: [overlayPath],
        );
        expect(index.skippedDocs, 1);
        expect(
          index.resolve('snap', 'firefox')?.toString(),
          'appstream:org.mozilla.firefox',
        );
      },
    );
  });

  group('saveOverlay', () {
    test('round-trip: save then load resolves the saved entry', () async {
      final overlayPath = '${temp.path}/nested/dir/overlay.json';
      await store.saveOverlay(overlayPath, [
        const CanonicalEntry(
          id: CanonicalAppId(
            CanonicalIdScheme.appstream,
            'org.example.SavedApp',
          ),
          displayName: 'Saved App',
          appstreamIds: ['org.example.SavedApp'],
          backendKeys: {
            'snap': ['saved-app'],
          },
          provenance: IdentityProvenance(source: 'test'),
        ),
      ]);
      // Parent dirs were created by saveOverlay.
      expect(File(overlayPath).existsSync(), isTrue);

      // The saved file has the exact overlay-doc shape.
      final raw = jsonDecode(await File(overlayPath).readAsString());
      expect(raw['schemaVersion'], 1);
      expect(raw['source'], 'local');
      expect(raw['entries'], isA<List>());

      // And it loads as an overlay over the seed.
      final index = await store.load(
        seedJson: kIdentitySeedJson,
        overlayPaths: [overlayPath],
      );
      expect(index.skippedDocs, 0);
      expect(
        index.resolve('snap', 'saved-app')?.toString(),
        'appstream:org.example.SavedApp',
      );
      // The seed still resolves alongside it.
      expect(
        index.resolve('snap', 'firefox')?.toString(),
        'appstream:org.mozilla.firefox',
      );
    });

    test('saved overlay merges with a hand-written overlay', () async {
      final handPath = '${temp.path}/hand.json';
      await File(handPath).writeAsString(
        _overlayDoc([
          _entry(
            canonicalId: 'appstream:org.example.HandApp',
            displayName: 'Hand App',
            backends: {
              'deb': ['hand-app'],
            },
          ),
        ]),
      );
      final savedPath = '${temp.path}/saved.json';
      await store.saveOverlay(savedPath, [
        const CanonicalEntry(
          id: CanonicalAppId(
            CanonicalIdScheme.homepage,
            'example.com/savedapp',
          ),
          backendKeys: {
            'deb': ['saved-app'],
          },
        ),
      ]);
      final index = await store.load(
        seedJson: kIdentitySeedJson,
        overlayPaths: [handPath, savedPath],
      );
      expect(
        index.resolve('deb', 'hand-app')?.toString(),
        'appstream:org.example.HandApp',
      );
      expect(
        index.resolve('deb', 'saved-app')?.toString(),
        'homepage:example.com/savedapp',
      );
    });
  });
}
