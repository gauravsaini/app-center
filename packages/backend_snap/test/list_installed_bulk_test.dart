import 'package:backend_snap/backend_snap.dart';
import 'package:backend_snap/testing.dart';
import 'package:test/test.dart';

/// Five scripted installed snaps. snap-1..3 carry no installedVersion —
/// the backend must fall back to the snap's own version; snap-4/5 keep
/// their own installedVersion.
List<SnapSummaryData> _fixture5() => [
  for (var i = 1; i <= 5; i++)
    SnapSummaryData(
      name: 'snap-$i',
      title: 'Snap $i',
      summary: 'summary $i',
      description: 'description $i',
      version: '1.$i',
      iconUrl: '',
      confinement: i.isEven ? 'classic' : 'strict',
      installedVersion: i > 3 ? '0.$i' : null,
    ),
];

/// Bulk listing always fails; the legacy N+1 path serves the fixture.
class _BulkFailingTransport extends StubSnapdTransport {
  _BulkFailingTransport(this._byName);

  final Map<String, SnapSummaryData> _byName;

  var installedNamesCalls = 0;
  var getDetailsCalls = 0;

  @override
  Future<List<SnapSummaryData>> installedSnaps() =>
      throw SnapdTransportException('connection refused');

  @override
  Future<List<String>> installedNames() async {
    installedNamesCalls++;
    return _byName.keys.toList();
  }

  @override
  Future<SnapSummaryData> getDetails(String name) async {
    getDetailsCalls++;
    final s = _byName[name];
    if (s == null) throw SnapdNotFoundException('snap "$name" not found');
    return s;
  }
}

void _expectSameApp(AppInfo a, AppInfo b) {
  expect(a.identity.backendId, b.identity.backendId);
  expect(a.identity.nativeId, b.identity.nativeId);
  expect(a.name, b.name);
  expect(a.summary, b.summary);
  expect(a.iconUrl, b.iconUrl);
  expect(a.source, b.source);
  expect(a.version, b.version);
  expect(a.installedVersion, b.installedVersion);
  expect(a.isInstalled, b.isInstalled);
}

void main() {
  group('BackendSnap.listInstalled bulk path', () {
    test('N=5 scripted snaps -> exactly 1 transport call', () async {
      final transport = StubSnapdTransport()
        ..scriptedInstalledSnaps = _fixture5();
      final backend = BackendSnap(transport: transport);

      final apps = await backend.listInstalled();

      expect(transport.installedSnapsCalls, 1);
      expect(apps, hasLength(5));
      expect(apps.map((a) => a.identity.nativeId), [
        'snap-1',
        'snap-2',
        'snap-3',
        'snap-4',
        'snap-5',
      ]);
    });

    test(
      'all entries report isInstalled with version fallback intact',
      () async {
        final transport = StubSnapdTransport()
          ..scriptedInstalledSnaps = _fixture5();
        final backend = BackendSnap(transport: transport);

        final apps = await backend.listInstalled();
        final byName = {for (final a in apps) a.identity.nativeId: a};

        for (final app in apps) {
          expect(app.isInstalled, isTrue, reason: app.identity.nativeId);
        }
        // No installedVersion from snapd: falls back to the snap version.
        expect(byName['snap-1']!.installedVersion, '1.1');
        expect(byName['snap-2']!.installedVersion, '1.2');
        expect(byName['snap-3']!.installedVersion, '1.3');
        // snapd-provided installedVersion is kept as-is.
        expect(byName['snap-4']!.installedVersion, '0.4');
        expect(byName['snap-5']!.installedVersion, '0.5');
      },
    );

    test('bulk failure falls back to the legacy N+1 path', () async {
      final fixture = _fixture5();
      final transport = _BulkFailingTransport({
        for (final s in fixture) s.name: s,
      });
      final backend = BackendSnap(transport: transport);

      final apps = await backend.listInstalled();

      expect(transport.installedNamesCalls, 1);
      expect(transport.getDetailsCalls, 5);
      expect(apps, hasLength(5));
      expect(apps.map((a) => a.identity.nativeId), [
        'snap-1',
        'snap-2',
        'snap-3',
        'snap-4',
        'snap-5',
      ]);
      expect(apps.every((a) => a.isInstalled), isTrue);
    });

    test(
      'bulk result matches legacy N+1 result for the same fixture',
      () async {
        final fixture = _fixture5();

        final bulkTransport = StubSnapdTransport()
          ..scriptedInstalledSnaps = fixture;
        final bulkApps = await BackendSnap(
          transport: bulkTransport,
        ).listInstalled();

        final legacyTransport = _BulkFailingTransport({
          for (final s in fixture) s.name: s,
        });
        final legacyApps = await BackendSnap(
          transport: legacyTransport,
        ).listInstalled();

        expect(bulkApps, hasLength(legacyApps.length));
        for (var i = 0; i < bulkApps.length; i++) {
          _expectSameApp(bulkApps[i], legacyApps[i]);
        }
      },
    );
  });
}
