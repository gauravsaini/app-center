# backend_appimage

The AppImage backend for the unified \*nix store (ADR-006) — a
**file-based transport** implementing the [`store_contracts`](../store_contracts)
law. No daemon, no registry: identity is the file's sha256
(content-addressed, stable across moves/renames/copies).

## Architecture

```
UI → store_host → BackendAppimage → AppImageTransport → filesystem +
                                                        AppImage runtime flags
                                                  ↑
                                   StubAppimageTransport (tests)
```

Everything the backend needs from the outside world goes through
`AppImageTransport`. Production uses `RealAppImageTransport` (dart:io for
files; metadata via the AppImage's own `--appimage-extract` /
`--appimage-offset` flags run on a private temp *copy* — never the user's
original file); tests script `StubAppimageTransport` and never touch the
live system.

## Capabilities

`search · details · install · remove`

## Flows

- **install(id)** — adopt/integrate: copy into `~/Applications`
  (`chmod +x`, sha256-verified) unless already there, write a managed
  `~/.local/share/applications/appimage-<slug>.desktop` with
  `X-LibreStore-*` provenance keys, cache the icon, record an install
  manifest. Idempotent: a manifest for the sha → `Done(noop: true)`.
- **remove(id)** — reverse the manifest: delete the `.desktop` entry,
  icon, and manifest; delete the managed copy only when install() made
  it. The user's original file is never touched.

## Honest limitations (v1)

- **`checkUpdates()` returns `[]`.** No catalog to diff against, no
  bundled zsync engine, per-app opt-in coverage (HLD §7).
- **No `permissions` capability.** AppImages run unsandboxed by design;
  details carry a static disclosure instead of a fake permission list.
- **Search is local-index-only.** The corpus is the scanned directories;
  `appimage.github.io/feed.json` is post-MVP (unstable format, links are
  release pages not download URLs).
- **Symlinked AppImages are not followed** by the scan (regular files
  only, MVP).
- **`recoverInFlight()` returns `[]`.** File-copy installs are short;
  nothing to re-attach to.

## Cancellation

`cancel()` flips a flag the operation body observes; partial copies are
deleted and the state machine lands on `Cancelled` (system unchanged) —
never a bare `Failed`.

## Running the contract exam

```dart
final backend = BackendAppimage(transport: RealAppImageTransport());
await runContractExam(
  'appimage',
  () => backend,
  installTarget: AppIdentity(backendId: 'appimage', nativeId: '<sha256>'),
  unknownTarget: AppIdentity(backendId: 'appimage', nativeId: '<unknown>'),
);
```

```bash
dart test            # contract exam + unit tests
dart analyze         # must be clean
```
