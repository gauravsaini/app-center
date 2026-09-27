/// Phase 3 identity slice 1: canonical identity types + IdentityIndex.
/// Implements the test matrix in docs/architecture/phase3-identity-lld.md §7.
library;

import 'dart:convert';

import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

Map<String, Object?> doc({
  int schemaVersion = 1,
  List<Map<String, Object?>> entries = const [],
  Map<String, String> aliases = const {},
}) => {'schemaVersion': schemaVersion, 'entries': entries, 'aliases': aliases};

Map<String, Object?> entry({
  required String canonicalId,
  String? displayName,
  List<String> appstreamIds = const [],
  List<String> homepages = const [],
  Map<String, List<String>> backends = const {},
  String provenance = 'seed',
}) => {
  'canonicalId': canonicalId,
  if (displayName != null) 'displayName': displayName,
  'appstreamIds': appstreamIds,
  'homepages': homepages,
  'backends': backends,
  'provenance': {'source': provenance},
};

Map<String, Object?> seedDoc() => doc(
  entries: [
    entry(
      canonicalId: 'appstream:org.mozilla.firefox',
      displayName: 'Firefox',
      appstreamIds: ['org.mozilla.firefox'],
      homepages: ['mozilla.org/firefox'],
      backends: {
        'snap': ['firefox'],
        'deb': ['firefox'],
        'flatpak': ['org.mozilla.firefox'],
      },
    ),
    entry(
      canonicalId: 'appstream:org.videolan.VLC',
      displayName: 'VLC',
      appstreamIds: ['org.videolan.VLC'],
      homepages: ['videolan.org/vlc'],
      backends: {
        'snap': ['vlc'],
        'deb': ['vlc'],
      },
    ),
    entry(
      canonicalId: 'appstream:org.gimp.GIMP',
      displayName: 'GIMP',
      appstreamIds: ['org.gimp.GIMP'],
      homepages: ['gimp.org'],
      backends: {
        'deb': ['gimp'],
      },
    ),
  ],
);

final firefoxId = CanonicalAppId.parse('appstream:org.mozilla.firefox');

void main() {
  group('CanonicalAppId.parse', () {
    test('valid appstream id', () {
      final id = CanonicalAppId.parse('appstream:org.mozilla.firefox');
      expect(id.scheme, CanonicalIdScheme.appstream);
      expect(id.value, 'org.mozilla.firefox');
    });

    test('valid homepage id', () {
      final id = CanonicalAppId.parse('homepage:mozilla.org/firefox');
      expect(id.scheme, CanonicalIdScheme.homepage);
      expect(id.value, 'mozilla.org/firefox');
    });

    test('value may contain colons', () {
      final id = CanonicalAppId.parse('homepage:example.com/a:b');
      expect(id.value, 'example.com/a:b');
    });

    test('rejects unknown scheme', () {
      expect(() => CanonicalAppId.parse('name:firefox'), throwsFormatException);
    });

    test('rejects empty value', () {
      expect(() => CanonicalAppId.parse('appstream:'), throwsFormatException);
    });

    test('rejects whitespace in value', () {
      expect(
        () => CanonicalAppId.parse('appstream:org.mozilla firefox'),
        throwsFormatException,
      );
      expect(
        () => CanonicalAppId.parse('appstream:\torg.mozilla.firefox'),
        throwsFormatException,
      );
    });

    test('rejects missing colon', () {
      expect(() => CanonicalAppId.parse('appstream'), throwsFormatException);
      expect(() => CanonicalAppId.parse(''), throwsFormatException);
    });
  });

  group('CanonicalAppId value semantics', () {
    test('== and hashCode on (scheme, value)', () {
      const a = CanonicalAppId(CanonicalIdScheme.appstream, 'org.mozilla.x');
      const b = CanonicalAppId(CanonicalIdScheme.appstream, 'org.mozilla.x');
      const c = CanonicalAppId(CanonicalIdScheme.homepage, 'org.mozilla.x');
      const d = CanonicalAppId(CanonicalIdScheme.appstream, 'org.mozilla.y');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('toString round-trips through parse', () {
      const ids = [
        CanonicalAppId(CanonicalIdScheme.appstream, 'org.mozilla.firefox'),
        CanonicalAppId(CanonicalIdScheme.homepage, 'mozilla.org/firefox'),
      ];
      for (final id in ids) {
        expect(CanonicalAppId.parse(id.toString()), equals(id));
      }
      expect(firefoxId.toString(), 'appstream:org.mozilla.firefox');
    });
  });

  group('normalizeHomepage', () {
    test('doc examples', () {
      expect(
        normalizeHomepage('https://www.mozilla.org/en-US/firefox/'),
        'mozilla.org/en-US/firefox',
      );
      expect(normalizeHomepage('http://videolan.org/vlc/'), 'videolan.org/vlc');
    });

    test('scheme case, www, host case, trailing slash', () {
      expect(normalizeHomepage('HTTP://WWW.Example.COM/A/'), 'example.com/A');
    });

    test('drops query and fragment', () {
      expect(
        normalizeHomepage('https://example.com/a?x=1#frag'),
        'example.com/a',
      );
    });

    test('host-only urls', () {
      expect(normalizeHomepage('https://example.com'), 'example.com');
      expect(normalizeHomepage('https://example.com/'), 'example.com');
    });

    test('garbage in -> stable garbage key, never throws', () {
      expect(normalizeHomepage('not a url'), 'not a url');
      expect(normalizeHomepage('not a url'), normalizeHomepage('not a url'));
    });

    test('empty -> empty', () {
      expect(normalizeHomepage(''), '');
    });
  });

  group('CanonicalEntry.fromJson', () {
    test('happy path, unknown fields ignored', () {
      final e = CanonicalEntry.fromJson({
        'canonicalId': 'appstream:org.mozilla.firefox',
        'displayName': 'Firefox',
        'appstreamIds': ['org.mozilla.firefox'],
        'homepages': ['mozilla.org/firefox'],
        'backends': {
          'deb': ['firefox'],
        },
        'provenance': {'source': 'seed', 'updatedAt': '2026-09-27T00:00:00Z'},
        'signature': 'reserved-for-later',
      });
      expect(e.id, equals(firefoxId));
      expect(e.displayName, 'Firefox');
      expect(e.appstreamIds, ['org.mozilla.firefox']);
      expect(e.homepages, ['mozilla.org/firefox']);
      expect(e.backendKeys, {
        'deb': ['firefox'],
      });
      expect(e.provenance.source, 'seed');
      expect(
        e.provenance.updatedAt!.toUtc().toIso8601String(),
        '2026-09-27T00:00:00.000Z',
      );
    });

    test('missing canonicalId -> FormatException', () {
      expect(
        () => CanonicalEntry.fromJson({'displayName': 'No id'}),
        throwsFormatException,
      );
    });

    test('unparseable canonicalId -> FormatException', () {
      expect(
        () => CanonicalEntry.fromJson({'canonicalId': 'name:firefox'}),
        throwsFormatException,
      );
    });

    test('wrong list/map shapes -> FormatException', () {
      expect(
        () => CanonicalEntry.fromJson({
          'canonicalId': 'appstream:x',
          'appstreamIds': 'not-a-list',
        }),
        throwsFormatException,
      );
      expect(
        () => CanonicalEntry.fromJson({
          'canonicalId': 'appstream:x',
          'backends': {'deb': 'firefox'},
        }),
        throwsFormatException,
      );
      expect(
        () => CanonicalEntry.fromJson({
          'canonicalId': 'appstream:x',
          'provenance': {'source': 'seed', 'updatedAt': 'not-a-date'},
        }),
        throwsFormatException,
      );
    });

    test('absent optional fields get defaults', () {
      final e = CanonicalEntry.fromJson({
        'canonicalId': 'appstream:org.example.App',
      });
      expect(e.displayName, isNull);
      expect(e.appstreamIds, isEmpty);
      expect(e.homepages, isEmpty);
      expect(e.backendKeys, isEmpty);
      expect(e.provenance.source, 'unknown');
      expect(e.provenance.updatedAt, isNull);
    });
  });

  group('IdentityIndex.resolve', () {
    late IdentityIndex index;
    setUp(() {
      index = IdentityIndex.fromJsonDocs([seedDoc()]);
    });

    test('backend-key hit', () {
      expect(index.resolve('deb', 'firefox'), equals(firefoxId));
      expect(
        index.resolve('flatpak', 'org.mozilla.firefox'),
        equals(firefoxId),
      );
    });

    test('appstream signal hit without backend key', () {
      expect(
        index.resolve(
          'rpm',
          'vlc',
          const IdentitySignal(appstreamId: 'org.videolan.VLC'),
        ),
        equals(CanonicalAppId.parse('appstream:org.videolan.VLC')),
      );
    });

    test('homepage signal hit with raw URL (scheme + www)', () {
      expect(
        index.resolve(
          'rpm',
          'firefox',
          const IdentitySignal(homepageUrl: 'https://www.mozilla.org/firefox/'),
        ),
        equals(firefoxId),
      );
    });

    test('ranking: backend-key beats appstream beats homepage', () {
      const signals = IdentitySignal(
        appstreamId: 'org.videolan.VLC',
        homepageUrl: 'https://www.gimp.org/',
      );
      // All three match differently -> curated backend key wins.
      expect(index.resolve('deb', 'firefox', signals), equals(firefoxId));
      // Backend key absent -> appstream signal wins over homepage.
      expect(
        index.resolve('rpm', 'not-in-index', signals),
        equals(CanonicalAppId.parse('appstream:org.videolan.VLC')),
      );
      // Only homepage matches -> homepage wins.
      expect(
        index.resolve(
          'rpm',
          'not-in-index',
          const IdentitySignal(homepageUrl: 'https://www.gimp.org/'),
        ),
        equals(CanonicalAppId.parse('appstream:org.gimp.GIMP')),
      );
    });

    test('unknown backend/key/signals -> null', () {
      expect(index.resolve('nope', 'x'), isNull);
      expect(index.resolve('deb', 'definitely-not-an-app'), isNull);
      expect(
        index.resolve(
          'deb',
          'definitely-not-an-app',
          const IdentitySignal(
            appstreamId: 'no.such.App',
            homepageUrl: 'https://example.com/nope',
          ),
        ),
        isNull,
      );
      // Empty lookup key skips the backend-key step.
      expect(index.resolve('deb', ''), isNull);
    });
  });

  group('IdentityIndex.entryFor', () {
    test('follows aliases', () {
      final index = IdentityIndex.fromJsonDocs([
        doc(
          entries: [
            entry(
              canonicalId: 'appstream:org.mozilla.firefox',
              displayName: 'Firefox',
            ),
          ],
          aliases: {
            'homepage:mozilla.org/firefox': 'appstream:org.mozilla.firefox',
          },
        ),
      ]);
      expect(
        index
            .entryFor(CanonicalAppId.parse('homepage:mozilla.org/firefox'))
            ?.id,
        equals(firefoxId),
      );
      // Direct lookup still works.
      expect(index.entryFor(firefoxId)?.displayName, 'Firefox');
      // Unknown -> null.
      expect(
        index.entryFor(CanonicalAppId.parse('appstream:no.such.App')),
        isNull,
      );
    });

    test('cycle guard terminates with null', () {
      final index = IdentityIndex.fromJsonDocs([
        doc(
          aliases: {
            'appstream:cycle.a': 'homepage:cycle.b',
            'homepage:cycle.b': 'appstream:cycle.a',
            'appstream:self': 'appstream:self',
          },
        ),
      ]);
      expect(index.entryFor(CanonicalAppId.parse('appstream:cycle.a')), isNull);
      expect(index.entryFor(CanonicalAppId.parse('appstream:self')), isNull);
    });
  });

  group('IdentityIndex layered merge', () {
    Map<String, Object?> layer1() => doc(
      entries: [
        entry(
          canonicalId: 'appstream:org.mozilla.firefox',
          displayName: 'Firefox',
          appstreamIds: ['org.mozilla.firefox'],
          homepages: ['mozilla.org/firefox'],
          backends: {
            'deb': ['firefox', ''],
            'snap': ['firefox'],
          },
          provenance: 'seed',
        ),
      ],
    );

    Map<String, Object?> layer2() => doc(
      entries: [
        entry(
          canonicalId: 'appstream:org.mozilla.firefox',
          displayName: 'Firefox Web Browser',
          appstreamIds: ['org.mozilla.firefox.esr'],
          backends: {
            'flatpak': ['org.mozilla.firefox'],
          },
          provenance: 'local',
        ),
      ],
    );

    test('overlay replaces scalars, unions signals, adds backend keys', () {
      final index = IdentityIndex.fromJsonDocs([layer1(), layer2()]);
      final e = index.entryFor(firefoxId)!;
      expect(e.displayName, 'Firefox Web Browser');
      expect(e.provenance.source, 'local');
      expect(e.appstreamIds, [
        'org.mozilla.firefox',
        'org.mozilla.firefox.esr',
      ]);
      expect(e.homepages, ['mozilla.org/firefox']);
      expect(e.backendKeys.keys.toSet(), {'deb', 'snap', 'flatpak'});
      // Empty backend keys are dropped at index build.
      expect(e.backendKeys['deb'], ['firefox']);
      // Resolution reflects the union.
      expect(
        index.resolve('flatpak', 'org.mozilla.firefox'),
        equals(firefoxId),
      );
      expect(
        index.resolve(
          'rpm',
          'x',
          const IdentitySignal(appstreamId: 'org.mozilla.firefox.esr'),
        ),
        equals(firefoxId),
      );
    });

    test('bad docs skipped and counted, rest loads', () {
      final badVersion = doc(
        schemaVersion: 2,
        entries: [entry(canonicalId: 'appstream:com.example.Bad')],
      );
      final badEntry = doc(
        entries: [
          {'displayName': 'missing canonicalId'},
          entry(canonicalId: 'appstream:com.example.AlsoBad'),
        ],
      );
      final index = IdentityIndex.fromJsonDocs([
        layer1(),
        badVersion,
        badEntry,
        layer2(),
      ]);
      expect(index.skippedDocs, 2);
      expect(index.entryCount, 1);
      // Valid layers still applied.
      expect(index.resolve('deb', 'firefox'), equals(firefoxId));
      expect(
        index.resolve('flatpak', 'org.mozilla.firefox'),
        equals(firefoxId),
      );
    });
  });

  group('IdentityIndex.toJson', () {
    test('canonical key order', () {
      final index = IdentityIndex.fromJsonDocs([
        doc(
          entries: [
            entry(
              canonicalId: 'appstream:org.mozilla.firefox',
              displayName: 'Firefox',
            ),
          ],
          aliases: {
            'homepage:mozilla.org/firefox': 'appstream:org.mozilla.firefox',
          },
        ),
      ]);
      final json = index.toJson();
      expect(json.keys.toList(), [
        'schemaVersion',
        'generatedAt',
        'source',
        'entries',
        'aliases',
      ]);
      final entryJson = (json['entries'] as List).first as Map<String, Object?>;
      expect(entryJson.keys.toList(), [
        'canonicalId',
        'displayName',
        'appstreamIds',
        'homepages',
        'backends',
        'provenance',
      ]);
    });

    test('omits null displayName and null updatedAt', () {
      final index = IdentityIndex.fromJsonDocs([
        doc(entries: [entry(canonicalId: 'appstream:org.example.App')]),
      ]);
      final entryJson =
          (index.toJson()['entries'] as List).first as Map<String, Object?>;
      expect(entryJson.containsKey('displayName'), isFalse);
      final provenance = entryJson['provenance'] as Map<String, Object?>;
      expect(provenance.keys.toList(), ['source']);
    });

    test('round-trip through fromJsonDocs preserves resolution', () {
      final index = IdentityIndex.fromJsonDocs([
        seedDoc(),
        doc(
          aliases: {
            'homepage:mozilla.org/firefox': 'appstream:org.mozilla.firefox',
          },
        ),
      ]);
      // Through real JSON text: the exact interchange path.
      final docJson =
          jsonDecode(jsonEncode(index.toJson())) as Map<String, Object?>;
      final rt = IdentityIndex.fromJsonDocs([docJson]);
      expect(rt.skippedDocs, 0);
      expect(rt.resolve('deb', 'firefox'), equals(firefoxId));
      expect(
        rt.resolve(
          'rpm',
          'x',
          const IdentitySignal(appstreamId: 'org.videolan.VLC'),
        ),
        equals(CanonicalAppId.parse('appstream:org.videolan.VLC')),
      );
      expect(
        rt.entryFor(CanonicalAppId.parse('homepage:mozilla.org/firefox'))?.id,
        equals(firefoxId),
      );
    });
  });

  group('IdentityIndex.empty', () {
    test('resolves nothing', () {
      final index = IdentityIndex.empty();
      expect(index.entryCount, 0);
      expect(index.skippedDocs, 0);
      expect(index.resolve('deb', 'firefox'), isNull);
      expect(index.entryFor(firefoxId), isNull);
    });
  });
}
