import 'dart:convert';

import 'package:store_contracts/store_contracts.dart';
import 'package:store_host/src/identity/seed_index.dart';
import 'package:test/test.dart';

/// Seed self-test: the bundled identity seed is hand-curated data, so it
/// gets a structural exam of its own. Every entry must be well-formed —
/// no duplicate canonical IDs, no empty fields, only known backend keys —
/// and the loaded index must resolve the entries it claims.
void main() {
  const allowedBackends = {
    'snap',
    'deb',
    'flatpak',
    'rpm',
    'pacman',
    'appimage',
  };

  group('identity seed', () {
    late Map<String, dynamic> doc;
    late List<dynamic> entries;

    setUpAll(() {
      doc = jsonDecode(kIdentitySeedJson) as Map<String, dynamic>;
      entries = doc['entries'] as List<dynamic>;
    });

    test('parses as JSON with the expected top-level shape', () {
      expect(doc['schemaVersion'], 1);
      expect(doc['source'], 'libreapp-center-seed');
      expect(entries, isNotEmpty);
    });

    test('no duplicate canonical IDs', () {
      final ids = entries
          .map((e) => (e as Map<String, dynamic>)['canonicalId'] as String)
          .toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('every entry is well-formed', () {
      for (final raw in entries) {
        final e = raw as Map<String, dynamic>;
        final cid = e['canonicalId'] as String;
        // CanonicalAppId.parse throws on anything but appstream:/homepage:.
        expect(
          () => CanonicalAppId.parse(cid),
          returnsNormally,
          reason: 'unparseable canonicalId: $cid',
        );
        expect(
          (e['displayName'] as String).trim(),
          isNotEmpty,
          reason: 'empty displayName: $cid',
        );
        final appstreamIds = e['appstreamIds'] as List<dynamic>;
        expect(appstreamIds, isNotEmpty, reason: 'no appstreamIds: $cid');
        final homepages = e['homepages'] as List<dynamic>;
        expect(homepages, isNotEmpty, reason: 'no homepages: $cid');
        final backends = e['backends'] as Map<String, dynamic>;
        expect(backends, isNotEmpty, reason: 'no backends: $cid');
        expect(
          backends.keys.toSet().difference(allowedBackends),
          isEmpty,
          reason: 'unknown backend key: $cid',
        );
        for (final entry in backends.entries) {
          final names = entry.value as List<dynamic>;
          expect(
            names,
            isNotEmpty,
            reason: 'empty package list: $cid/${entry.key}',
          );
        }
      }
    });

    test('seed loads and resolves its own backend keys', () {
      final index = IdentityIndex.fromJsonDocs([
        Map<String, Object?>.from(doc),
      ]);
      expect(index.entryCount, entries.length);
      // Spot-check one original and two expansion entries end to end.
      expect(
        index.resolve('snap', 'firefox')?.toString(),
        'appstream:org.mozilla.firefox',
      );
      expect(
        index.resolve('snap', 'brave')?.toString(),
        'appstream:com.brave.Browser',
      );
      expect(
        index.resolve('flatpak', 'org.darktable.Darktable')?.toString(),
        'appstream:org.darktable.Darktable',
      );
      expect(
        index.resolve('pacman', 'prismlauncher')?.toString(),
        'appstream:org.prismlauncher.PrismLauncher',
      );
    });
  });
}
