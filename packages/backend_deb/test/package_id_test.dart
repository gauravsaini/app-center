/// DebPackageId parsing + corrupt-id policy tests (deb-packageid-fix.md).
///
/// Fixture IDs only — never touches D-Bus.
library;

import 'package:backend_deb/backend_deb.dart';
import 'package:test/test.dart';

void main() {
  group('DebPackageId', () {
    test('parses a real apt 5-token id', () {
      final id = DebPackageId.parse(
        'firefox;135.0-1;amd64;jammy-updates;manual',
      );
      expect(id.name, 'firefox');
      expect(id.version, '135.0-1');
      expect(id.arch, 'amd64');
      expect(id.origin, 'jammy-updates');
      expect(id.data, 'manual');
    });

    test('version is opaque: epoch-bearing versions survive verbatim', () {
      final id = DebPackageId.parse('libc6;2:2.35-0ubuntu3;amd64;jammy;manual');
      expect(id.version, '2:2.35-0ubuntu3');
      expect(id.toString(), 'libc6;2:2.35-0ubuntu3;amd64;jammy;manual');
    });

    test('verbatim round-trip', () {
      const raw = 'vim;2:9.0.1000-1;amd64;jammy;auto';
      expect(DebPackageId.parse(raw).toString(), raw);
    });

    test(
      '4-token id throws FormatException (the old vendored parser shape)',
      () {
        expect(
          () => DebPackageId.parse('firefox;135.0-1;amd64;manual'),
          throwsFormatException,
        );
      },
    );

    test('empty name throws FormatException', () {
      expect(
        () => DebPackageId.parse(';1.0;amd64;jammy;manual'),
        throwsFormatException,
      );
    });

    test('empty string throws FormatException', () {
      expect(() => DebPackageId.parse(''), throwsFormatException);
    });
  });

  group('corrupt-id policy', () {
    test('unparsable package ids are skipped, never fatal', () {
      final merged = RealPackageKitTransport.mergeInstalledPackages([
        const DebRawPackage(
          installed: true,
          id: 'good;1.0;amd64;jammy;manual',
          summary: 'good',
        ),
        // 4-token garbage a confused daemon might emit: skipped.
        const DebRawPackage(
          installed: true,
          id: 'bad;1.0;amd64;manual',
          summary: 'bad',
        ),
        const DebRawPackage(installed: true, id: '', summary: 'empty'),
      ], const []);
      expect(merged, hasLength(1));
      expect(merged.first.name, 'good');
    });

    test('unparsable details ids do not break the merge', () {
      final merged = RealPackageKitTransport.mergeInstalledPackages(
        [
          const DebRawPackage(
            installed: true,
            id: 'good;1.0;amd64;jammy;manual',
            summary: 'pkg summary',
          ),
        ],
        [
          const DebRawDetails(id: 'not-an-id', summary: 'x', description: 'y'),
          const DebRawDetails(
            id: 'good;1.0;amd64;jammy;manual',
            summary: 'detail summary',
            description: 'detail description',
          ),
        ],
      );
      expect(merged, hasLength(1));
      expect(merged.first.summary, 'detail summary');
      expect(merged.first.description, 'detail description');
    });
  });

  group('mapping parity', () {
    test('5-token fixtures produce the same cards the old tests asserted', () {
      // Mirrors the pre-fix multi-arch expectations (name, version,
      // installedVersion, summary/description preference) with real
      // 5-token daemon IDs instead of the vendored 4-token fixtures.
      final merged = RealPackageKitTransport.mergeInstalledPackages(
        [
          const DebRawPackage(
            installed: true,
            id: 'libfoo;1.0;amd64;jammy;manual',
            summary: 'foo',
          ),
          const DebRawPackage(
            installed: true,
            id: 'libfoo;1.0;i386;jammy;manual',
            summary: 'foo',
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
      expect(merged, hasLength(1));
      final card = merged.single;
      expect(card.name, 'libfoo');
      expect(card.version, '1.0');
      expect(card.installedVersion, '1.0');
      expect(card.summary, 'foo summary');
      expect(card.description, 'foo description');
    });

    test('available (non-installed) entries keep installedVersion null', () {
      final merged = RealPackageKitTransport.mergeInstalledPackages([
        const DebRawPackage(
          installed: false,
          id: 'candidate;2.0;amd64;jammy;',
          summary: 'candidate',
        ),
      ], const []);
      expect(merged, hasLength(1));
      expect(merged.single.version, '2.0');
      expect(merged.single.installedVersion, isNull);
    });
  });
}
