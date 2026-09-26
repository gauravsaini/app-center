# store_host

Host-side orchestration for the unified \*nix store: backend registry,
feature flags, unified catalog fan-out, and the operation engine.

## Usage

```dart
import 'package:store_host/store_host.dart';
import 'package:backend_flatpak/backend_flatpak.dart'; // composition root ONLY

final flags = MapFeatureFlags();
final host = StoreHost(flags: flags);
host.registerBackend(BackendFlatpak(transport: CliFlatpakTransport()));

// Search fans out across enabled + available backends.
// One UnifiedApp card per backend result (no unsafe merging).
await for (final card in host.search('vlc')) {
  print('${card.groupId}: ${card.preferred.name}');
}

// Operations: one active op per app; a second enqueue returns the
// existing handle.
final handle = await host.enqueue(OperationKind.install, app);
await for (final state in handle.state) {
  print(state);
}

// Details + permissions (pre-install where the backend knows them).
final details = await host.getDetails(app);
```

## Design notes

- **UI imports only `store_host` + `store_contracts`.** Backends are
  constructed at the composition root and registered; the dependency
  arrow never points from UI to `backend_*`.
- **Missing backends are normal.** A backend that is flag-disabled or
  whose `isAvailable()` is false is silently absent from results.
- **Partial degradation.** A backend that throws or stalls past
  `catalog.search_timeout_ms` contributes nothing; the search still
  completes with the other backends' results.
- **v1 limits** (see `docs/architecture/host-wiring.md`): no
  cross-backend card merging, `installed()` returns `[]` pending a
  `listInstalled()` contract addition, `checkUpdates()` is uncached,
  `authenticateBatch` is a no-op.

## Tests

```bash
dart test     # 12 tests: fan-out, flag gating, availability gating,
              # partial degradation, enqueue dedup, activeOperations
dart analyze  # must be clean
```
