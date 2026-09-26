import 'dart:async';

import 'package:backend_flatpak/backend_flatpak.dart' show BackendFlatpak;
import 'package:store_host/store_host.dart';
import 'package:test/test.dart';

import 'stub_backends.dart';

const _flatpakApp = AppIdentity(backendId: 'flatpak', nativeId: 'org.test.App');
const _flatpakInstalled = AppIdentity(
  backendId: 'flatpak',
  nativeId: 'org.test.Installed',
);

StoreHost makeHost({Map<String, Object>? flags}) {
  final merged = {'backend.snap.enabled': true, ...?flags};
  final host = StoreHost(flags: MapFeatureFlags(merged));
  host.registerBackend(BackendFlatpak(transport: StubFlatpakTransport()));
  host.registerBackend(StubSnapBackend());
  return host;
}

void main() {
  group('StoreHost catalog', () {
    test('search fans out across enabled backends as separate cards', () async {
      final host = makeHost();
      final cards = await host.search('test').toList();
      final ids = cards.map((c) => c.groupId).toSet();
      // One card per backend result — no unsafe cross-format merging.
      expect(ids, contains('flatpak:org.test.App'));
      expect(ids, contains('snap:snap.test.App'));
      expect(cards.every((c) => c.variants.length == 1), isTrue);
    });

    test('backend.flatpak.enabled=false excludes flatpak', () async {
      final host = makeHost(flags: {'backend.flatpak.enabled': false});
      final cards = await host.search('test').toList();
      final ids = cards.map((c) => c.groupId).toSet();
      expect(ids, isNot(contains('flatpak:org.test.App')));
      expect(ids, contains('snap:snap.test.App'));
    });

    test('unavailable backend is excluded even when flag-enabled', () async {
      final host = StoreHost(
        flags: MapFeatureFlags({
          'backend.snap.enabled': true,
          // backend.flatpak.enabled defaults to true.
        }),
      );
      host.registerBackend(
        BackendFlatpak(transport: FailingFlatpakTransport()),
      );
      host.registerBackend(StubSnapBackend());
      final cards = await host.search('test').toList();
      expect(cards.map((c) => c.groupId), everyElement(startsWith('snap:')));
    });

    test('a failing backend degrades to partial results', () async {
      final host = StoreHost(
        flags: MapFeatureFlags({
          'backend.snap.enabled': true,
          'backend.thrower.enabled': true,
        }),
      );
      host.registerBackend(ThrowingSearchBackend());
      host.registerBackend(StubSnapBackend());
      final cards = await host.search('test').toList();
      // throwing backend contributed nothing, snap results arrived,
      // and the stream still closed cleanly.
      expect(cards.map((c) => c.groupId), ['snap:snap.test.App']);
    });

    test('search rejects empty/oversize queries', () {
      final host = makeHost();
      expect(() => host.search(''), throwsArgumentError);
      expect(() => host.search('x' * 201), throwsArgumentError);
    });

    test('getDetails surfaces permissions', () async {
      final host = makeHost();
      final details = await host.getDetails(_flatpakInstalled);
      expect(details.permissions, isNotEmpty);
      expect(details.app.identity.backendId, 'flatpak');
    });

    test('getDetails on unknown backend throws typed error', () async {
      final host = makeHost();
      await expectLater(
        host.getDetails(const AppIdentity(backendId: 'nope', nativeId: 'x')),
        throwsA(isA<BackendUnavailableException>()),
      );
    });
  });

  group('StoreHost operation engine', () {
    test(
      'second enqueue for the same app returns the existing handle',
      () async {
        final host = makeHost();
        final h1 = await host.enqueue(OperationKind.install, _flatpakApp);
        final h2 = await host.enqueue(OperationKind.install, _flatpakApp);
        expect(identical(h1, h2), isTrue);
        // Let it finish so the slot releases.
        await h1.state.where((s) => s.isTerminal).first;
        final h3 = await host.enqueue(OperationKind.install, _flatpakApp);
        expect(identical(h1, h3), isFalse);
      },
    );

    test('activeOperations tracks in-flight then empties', () async {
      final host = makeHost();
      final seen = <List<OperationHandle>>[];
      final sub = host.activeOperations().listen(seen.add);
      final h = await host.enqueue(OperationKind.install, _flatpakApp);
      await h.state.where((s) => s.isTerminal).first;
      // Give the terminal watcher a turn to release the slot.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(seen.first, isEmpty);
      expect(seen.any((l) => l.length == 1), isTrue);
      expect(seen.last, isEmpty);
    });

    test('enqueue on disabled backend throws typed error', () async {
      final host = makeHost(flags: {'backend.flatpak.enabled': false});
      await expectLater(
        host.enqueue(OperationKind.install, _flatpakApp),
        throwsA(isA<BackendUnavailableException>()),
      );
    });
  });

  group('MapFeatureFlags', () {
    test('unknown keys return defaults, never throw', () {
      final flags = MapFeatureFlags();
      expect(flags.isEnabled('backend.flatpak.enabled'), isTrue);
      expect(flags.isEnabled('backend.snap.enabled'), isTrue);
      expect(flags.getString('catalog.backend_order'), 'flatpak,snap');
      expect(flags.isEnabled('no.such.key'), isFalse);
      expect(flags.getInt('catalog.search_timeout_ms'), 5000);
      expect(flags.getInt('no.such.key'), 0);
    });

    test('setFlag notifies via changes', () async {
      final flags = MapFeatureFlags();
      final future = flags.changes.first;
      flags.setFlag('backend.flatpak.enabled', false);
      expect(await future, 'backend.flatpak.enabled');
      expect(flags.isEnabled('backend.flatpak.enabled'), isFalse);
    });
  });
}
