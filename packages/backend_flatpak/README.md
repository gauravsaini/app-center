# backend_flatpak

The Flatpak backend for the unified \*nix store (ADR-006) — a **CLI-wrapper
transport** implementing the [`store_contracts`](../store_contracts) law.

## Architecture

```
UI → store_host → BackendFlatpak → FlatpakTransport → flatpak(1)
                                          ↑
                                   StubFlatpakTransport (tests)
```

Everything the backend needs from the outside world goes through
`FlatpakTransport`. Production uses `CliFlatpakTransport` (spawns the
`flatpak` binary); tests script `StubFlatpakTransport` and never touch
the live system. This is what makes the backend testable on machines
without flatpak installed.

## Capabilities

`search · details · install · remove · update · permissions`

## Honest limitations (v1)

- **Search parsing is heuristic.** `flatpak search` prints an aligned
  table with no stable machine-readable format; rows are parsed by
  finding the reverse-DNS app-id token. Brittle by nature — hardening
  is future work.
- **`checkUpdates()` returns `[]`.** `flatpak update` has no stable
  dry-run interface across versions; updates surface via `update()` on
  demand.
- **`recoverInFlight()` returns `[]`.** A CLI wrapper cannot re-attach
  to processes from a previous app lifetime.
- **Permissions** come from `flatpak info --show-permissions` and are
  therefore only available for *installed* apps. They still surface
  pre-install wherever the host already knows them (ADR-009).

## Cancellation

`cancel()` sends SIGTERM, then SIGKILL after a 2s grace. The state
machine lands on `Cancelled` (system unchanged) — or an honest
`Done(cancelRequested: true)` when the process already finished.

## Running the contract exam

```dart
final backend = BackendFlatpak(transport: CliFlatpakTransport());
await runContractExam(
  'flatpak',
  () => backend,
  installTarget: AppIdentity(backendId: 'flatpak', nativeId: 'org.videolan.VLC'),
  unknownTarget: AppIdentity(backendId: 'flatpak', nativeId: 'no.such.App'),
);
```

```bash
dart test            # contract exam + parser unit tests
dart analyze         # must be clean
```
