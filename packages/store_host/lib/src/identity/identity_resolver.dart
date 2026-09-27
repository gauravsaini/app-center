/// [IdentityResolver]: cross-format identity resolution over an
/// [IdentityIndex] (Phase 3 identity, slice 1).
///
/// Implements `docs/architecture/phase3-identity-lld.md` §5.3. This is
/// the one identity type re-exported from `store_host.dart`: everything
/// else in `src/identity/` is host-internal plumbing.
library;

import 'package:store_contracts/store_contracts.dart';

class IdentityResolver {
  IdentityResolver({
    required this.index,
    required Map<String, StoreBackend> backends,
  }) : _backends = Map.unmodifiable(backends);

  final IdentityIndex index;
  final Map<String, StoreBackend> _backends;

  /// backendId -> backend, as given.
  Map<String, StoreBackend> get backends => _backends;

  /// Resolves [id] to a canonical id, or null when unresolved.
  ///
  /// The lookup key is arch- and version-agnostic
  /// ([StoreBackend.identityLookupKey]) — it is NOT the backend's card
  /// key. Unknown [AppIdentity.backendId] resolves to null; never
  /// throws.
  CanonicalAppId? resolve(AppIdentity id, [IdentitySignal? signals]) {
    final backend = _backends[id.backendId];
    if (backend == null) return null;
    return index.resolve(id.backendId, backend.identityLookupKey(id), signals);
  }

  /// The curated entry for a canonical id, following aliases. Null
  /// when unknown.
  CanonicalEntry? entryFor(CanonicalAppId canonicalId) =>
      index.entryFor(canonicalId);
}
