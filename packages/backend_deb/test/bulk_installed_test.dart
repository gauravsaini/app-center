import 'package:backend_deb/backend_deb.dart';
import 'package:backend_deb/testing.dart';
import 'package:test/test.dart';

void main() {
  group('deb bulk listInstalled', () {
    test('N=5 scripted packages cost exactly 2 transactions', () async {
      final transport = StubPackageKitTransport()
        ..installedPackagesScript = [
          for (var i = 1; i <= 4; i++)
            DebPackageData(
              name: 'pkg-$i',
              summary: 'summary $i',
              description: 'description $i',
              version: '1.$i',
              installedVersion: '1.$i',
            ),
          // No installedVersion: the backend falls back to the
          // package's own version, which IS the installed one here.
          const DebPackageData(
            name: 'pkg-5',
            summary: 'summary 5',
            description: 'description 5',
            version: '5.0',
          ),
        ];
      final backend = BackendDeb(transport: transport);

      final apps = await backend.listInstalled();

      // Bulk: 1 GetPackages(installed) + 1 GetDetails batch. The legacy
      // path would have spent 1 + 2*5 = 11.
      expect(transport.transactionCount, 2);
      expect(apps, hasLength(5));
      for (var i = 0; i < 4; i++) {
        final app = apps[i];
        expect(app.identity.backendId, 'deb');
        expect(app.identity.nativeId, 'pkg-${i + 1}');
        expect(app.source, AppSource.deb);
        expect(app.isInstalled, isTrue);
        expect(app.installedVersion, '1.${i + 1}');
      }
      expect(apps[4].identity.nativeId, 'pkg-5');
      expect(apps[4].isInstalled, isTrue);
      expect(apps[4].installedVersion, '5.0');
    });

    test('bulk descriptions survive at the transport data level', () async {
      // AppInfo carries no description (it surfaces via getDetails),
      // so description preservation is asserted on the DebPackageData
      // the bulk path fetched.
      final transport = StubPackageKitTransport()
        ..installedPackagesScript = const [
          DebPackageData(
            name: 'pkg-a',
            summary: 'a',
            description: 'the long description of pkg-a',
            version: '1.0',
            installedVersion: '1.0',
          ),
        ];

      final packages = await transport.installedPackages();

      expect(packages, hasLength(1));
      expect(packages.first.description, 'the long description of pkg-a');
      expect(transport.transactionCount, 2);
    });

    test('multi-arch duplicate names collapse to one entry', () {
      // 5-token IDs as a real apt daemon emits them
      // (name;version;arch;origin;data).
      DebRawPackage pkg(String arch) => DebRawPackage(
        installed: true,
        id: 'libfoo;1.0;$arch;jammy;manual',
        summary: 'foo',
      );
      final merged = RealPackageKitTransport.mergeInstalledPackages(
        [
          pkg('amd64'),
          pkg('i386'),
          const DebRawPackage(
            installed: true,
            id: 'bar;2.0;amd64;jammy;manual',
            summary: 'bar',
          ),
        ],
        [
          const DebRawDetails(
            id: 'libfoo;1.0;amd64;jammy;manual',
            summary: 'foo summary',
            description: 'foo description',
          ),
        ],
      );

      expect(merged, hasLength(2));
      final libfoo = merged.firstWhere((p) => p.name == 'libfoo');
      expect(libfoo.installedVersion, '1.0');
      expect(libfoo.summary, 'foo summary');
      expect(libfoo.description, 'foo description');
      // No details event for bar: description stays empty, summary
      // falls back to the package event's.
      final bar = merged.firstWhere((p) => p.name == 'bar');
      expect(bar.installedVersion, '2.0');
      expect(bar.summary, 'bar');
      expect(bar.description, isEmpty);
    });

    test('bulk failure falls back to the legacy N+1 path', () async {
      final transport = StubPackageKitTransport()
        ..installedNamesScript = const [
          'pkg-a',
          'pkg-b',
          'pkg-c',
          'pkg-d',
          'pkg-e',
        ]
        ..installedPackagesFailure = PackageKitTransportException(
          'packagekit details timed out',
        );
      for (final name in transport.installedNamesScript) {
        transport.detailsScript[name] = DebPackageData(
          name: name,
          summary: 'summary of $name',
          description: 'description of $name',
          version: '1.0',
        );
      }
      final backend = BackendDeb(transport: transport);

      final apps = await backend.listInstalled();

      expect(apps.map((a) => a.identity.nativeId), [
        'pkg-a',
        'pkg-b',
        'pkg-c',
        'pkg-d',
        'pkg-e',
      ]);
      expect(apps.every((a) => a.isInstalled), isTrue);
      // 2 attempted bulk transactions + legacy 1 names + 2*5 details.
      expect(transport.transactionCount, 2 + 1 + 2 * 5);
    });
  });
}
