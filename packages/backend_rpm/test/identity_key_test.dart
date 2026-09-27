/// identityLookupKey contract (phase3-identity-lld.md §3):
/// arch- and version-agnostic — the bare package name, never the card
/// key. Total function: malformed ids return the nativeId, never throw.
library;

import 'package:backend_rpm/backend_rpm.dart';
import 'package:backend_rpm/testing.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

BackendRpm _create() => BackendRpm(transport: StubRpmTransport());

AppIdentity _id(String nativeId) =>
    AppIdentity(backendId: 'rpm', nativeId: nativeId);

void main() {
  group('identityLookupKey', () {
    final backend = _create();

    test('x86_64 id resolves to the bare package name', () {
      expect(
        backend.identityLookupKey(
          _id('firefox;136.0-1.fc42;x86_64;updates;installed'),
        ),
        'firefox',
      );
    });

    test('is arch-agnostic: i686 maps to the same key as x86_64', () {
      expect(
        backend.identityLookupKey(
          _id('firefox;136.0-1.fc42;i686;updates;installed'),
        ),
        'firefox',
      );
      expect(
        backend.identityLookupKey(_id('firefox;136.0-1.fc42;x86_64;updates;')),
        backend.identityLookupKey(
          _id('firefox;136.0-1.fc42;i686;updates;installed'),
        ),
      );
    });

    test('malformed nativeId returns the input, never throws', () {
      const bad = 'not;a;valid;id';
      expect(backend.identityLookupKey(_id(bad)), bad);
      expect(backend.identityLookupKey(_id('')), '');
    });
  });
}
