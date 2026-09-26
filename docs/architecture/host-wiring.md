# Host wiring — how the UI consumes the host

## The layering rule

```
Flutter pages → store_host → store_contracts
                     ↑
              composition root (main.dart)
                     ↓
        backend_flatpak / backend_snap / backend_deb
```

- UI pages import **only** `store_host` and `store_contracts`. Never `backend_*`.
- Backends are constructed **once** in the composition root and
  registered via `StoreHost.registerBackend`. The dependency arrow
  points one way: app → backends → contracts.
- `scripts/dep_trace.py` is the enforcer: any UI → `backend_*`
  import is a violation, same class as the 44 snapd violations it
  already tracks.

## Composition root (sketch)

```dart
final flags = MapFeatureFlags(); // load persisted overrides here
final host = StoreHost(flags: flags);
host.registerBackend(BackendFlatpak(transport: CliFlatpakTransport()));
// host.registerBackend(BackendSnap(...));   // future
// host.registerBackend(BackendDeb(...));    // future
```

`Provider<StoreHost>` (or equivalent) exposes the host to pages.
A page search becomes:

```dart
host.search(query).listen((card) => ...); // Stream<UnifiedApp>
```

Cancelling the subscription stops backend work (each backend's
search is itself cancellable).

## Flag semantics

| Flag | Default | Meaning |
|---|---|---|
| `backend.flatpak.enabled` | `true` | Kill switch for the Flatpak backend |
| `catalog.backend_order` | `flatpak` | Preferred format order for future dedup ranking |
| `catalog.search_timeout_ms` | `5000` | Per-backend search stall budget; excess → partial results |
| `engine.stall_timeout_ms` | `30000` | Reserved: stall watchdog budget |
| `engine.max_concurrent_per_backend` | `1` | Reserved: per-backend concurrency cap |
| `engine.history_ttl_ms` | `3600000` | Reserved: operation history retention |

Unknown keys read their documented default — never throw. Every flag
needs an owner and a removal date before it ships to users (ADR-010);
the `engine.*` / `catalog.backend_order` rows above are reserved and
not yet consumed.

Availability is checked live: a backend whose `isAvailable()` is false
(a missing `flatpak` binary, a dead snapd) is simply absent from
results. Missing backends are a normal runtime condition.

## What v1 deliberately does not do

- **No cross-backend merging.** One `AppInfo` → one `UnifiedApp` card.
  The thesis prefers duplicate cards over unsafe merges; real merging
  arrives with the community metadata index, not heuristics.
- **`installed()` returns `[]`.** Needs a `StoreBackend.listInstalled()`
  contract addition (minor SemVer bump + exam coverage) — a later,
  deliberate contract change, not a quiet hack.
- **`checkUpdates()` is uncached and unstaggered.** The contract says it
  must not run on the UI critical path; scheduling (stagger, cache,
  background) is the app's concern when it wires the Updates page.
- **`authenticateBatch` is a no-op.** CLI backends escalate per command;
  cross-command auth coalescing is vehicle-specific future work.

## Strangler next steps

1. `backend_snap`: implement `StoreBackend` over snapd, pass the exam.
2. Register it in the composition root; Explore page reads from host.
3. `backend_deb` via PackageKit, same exam.
4. `StoreBackend.listInstalled()` contract addition → real `installed()`.
5. Merge heuristics only when the metadata index can back them.
