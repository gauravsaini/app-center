/// identityLookupKey contract (phase3-identity-lld.md §3):
/// arch- and version-agnostic — the bare package name. Total function:
/// malformed ids return the nativeId, never throw. Also covers the
/// StoreBackend default (nativeId unchanged) for backends that don't
/// override.
library;

import 'dart:async';

import 'package:backend_pacman/backend_pacman.dart';
import 'package:backend_pacman/testing.dart';
import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

BackendPacman _create() => BackendPacman(transport: StubPacmanTransport());

AppIdentity _id(String nativeId) =>
    AppIdentity(backendId: 'pacman', nativeId: nativeId);

/// A backend that inherits the [StoreBackend.identityLookupKey]
/// default: pins the default behavior in a regression test.
class _DefaultKeyBackend extends StoreBackend {
  @override
  String get id => 'default-key';

  @override
  int get contractVersion => storeContractsMajor;

  @override
  Set<BackendCapability> get capabilities => {};

  @override
  Future<bool> isAvailable() => Future.value(false);

  @override
  Stream<AppInfo> search(String query) => const Stream.empty();

  @override
  Future<AppDetails> getDetails(AppIdentity id) =>
      throw AppNotFoundException(backendId: this.id, debugDetail: 'stub');

  @override
  Future<OperationHandle> install(AppIdentity id) => throw UnimplementedError();

  @override
  Future<OperationHandle> remove(AppIdentity id) => throw UnimplementedError();

  @override
  Future<OperationHandle> update(AppIdentity id) => throw UnimplementedError();

  @override
  Future<List<UpdateInfo>> checkUpdates() => Future.value(const []);

  @override
  Future<List<OperationHandle>> recoverInFlight() => Future.value(const []);
}

void main() {
  group('identityLookupKey', () {
    final backend = _create();

    test('resolves to the bare package name', () {
      expect(backend.identityLookupKey(_id('firefox;146.0-1;;')), 'firefox');
    });

    test('is version- and arch-agnostic', () {
      expect(
        backend.identityLookupKey(_id('firefox;146.0-1;x86_64;extra')),
        'firefox',
      );
      expect(
        backend.identityLookupKey(_id('firefox;146.0.1-1;;')),
        backend.identityLookupKey(_id('firefox;146.0-1;x86_64;extra')),
      );
    });

    test('malformed nativeId returns the input, never throws', () {
      const bad = 'firefox;146.0-1';
      expect(backend.identityLookupKey(_id(bad)), bad);
      expect(backend.identityLookupKey(_id('')), '');
    });

    test('StoreBackend default returns nativeId unchanged', () {
      final stub = _DefaultKeyBackend();
      const nativeId = 'firefox;146.0-1;;';
      expect(stub.identityLookupKey(_id(nativeId)), nativeId);
    });
  });
}
