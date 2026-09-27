# HLD: AppImage backend (`packages/backend_appimage`)

Status: design locked (2026-09-27). Implements grandvision.md Phase 1
("more backends as plugins"). Research: `appimage-research.md` (live
artifact inspection, verified 2026-09-27).

## 1. Goal

A `StoreBackend` plugin for AppImage — the format with no daemon, no
central registry, no package manager. The host thesis holds: "one app,
one card — the format is a detail." This slice is the backend plugin
only. No cross-format identity merging (deferred to Phase 3 per HLD v1
grouping policy); no UI changes beyond the composition root.

## 2. Non-goals

- Network catalog search (appimage.github.io `feed.json` is live but
  explicitly unstable; links are release *pages*, not download URLs).
- In-place updates (zsync is per-app opt-in; no engine on stock Ubuntu).
- FUSE mounting for metadata (needs privileges; slow).
- Managing AppImages the user never asked about (we only integrate
  files the user installs/adopts through the store).

## 3. Architecture

```
packages/backend_appimage/
  lib/backend_appimage.dart      # barrel: backend, identity helpers
  lib/testing.dart               # StubAppimageTransport (tests only)
  lib/src/transport.dart         # AppImageTransport (injectable seam)
  lib/src/backend.dart           # BackendAppimage extends StoreBackend
  lib/src/handle.dart            # AppimageOperationHandle
  lib/src/metadata.dart          # .desktop parse, filename heuristics
  lib/src/identity.dart          # sha256 identity + index cache key
  test/exam_test.dart            # runContractExam + unit tests
```

All outside-world contact (filesystem, processes) goes through
`AppImageTransport`, mirroring the flatpak backend's ADR-006 pattern.
Tests script a stub; production uses `RealAppImageTransport`.

### Interface contracts

**AppImageTransport** — the only impure seam:
- `listDir(String path)` → `List<DirEntry>` (name, isFile, size, mtimeMs).
  Missing dir → `[]`, never throws.
- `readHead(String path, int n)` → first `n` bytes (magic check).
- `sha256Of(String path)` → hex digest (streaming; never whole-file in RAM).
- `extractDesktop(String appImagePath, String outDir)` → path of the
  extracted `.desktop` file. Strategy: `unsquashfs -l`-style single-file
  extract when the binary exists, else copy → `chmod +x` the *copy* →
  `<copy> --appimage-extract` in `outDir`. Never chmod / never execute
  the user's original file.
- `copyFile`, `writeTextFile`, `deleteFile`, `chmodX`
  — thin, typed-error wrappers.

**AppImageIndex** (in-memory, per backend instance):
- Built by `listInstalled()` scan; maps `sha256 → IndexedApp{path, size,
  mtimeMs, name, version?}`.
- Identity cache key: `(path, size, mtimeMs)` — re-hash only when the
  file changed. Scan cost stays O(files), hashing is lazy.

**BackendAppimage** (`id: 'appimage'`, `contractVersion: storeContractsMajor`):
- `capabilities = {search, details, install, remove}`.
  - No `update`: zsync is opt-in per app and needs an engine absent on
    stock Ubuntu. `checkUpdates()` → `[]` (honest, documented).
  - No `permissions`: AppImage is unsandboxed by design; details carry a
    static disclosure string instead of a fake permission list.
  - No `ratings`: same as other backends (ADR-005).
- `isAvailable()`: true when `$HOME` resolves and is readable; <200ms,
  no side effects, safe twice.
- `listInstalled()`: non-recursive scan of
  `~/Applications`, `~/.local/bin`, `~/bin`, `~/Downloads`, `/opt`,
  `/usr/local/bin`, `/Applications` → prefilter `*.AppImage`/`*.appimage`
  or executable bit → verify ELF + `AI\x01`/`AI\x02` magic at offset 8 →
  `AppInfo(identity: sha256, source: AppSource.appImage,
  installedVersion: <version or 'unknown'>)`. Missing dirs are normal.
  Throws `StoreException` subtypes only.
- `search(query)`: substring match over the in-memory index
  (name + filename, case-insensitive). Cancellable: the scan loop
  checks a flag between directories; cancel → close stream, no orphans.
- `getDetails(id)`: resolve sha256 → path via index (re-scan if stale);
  unknown → `AppNotFoundException`. Lazy full metadata: extract
  `.desktop` (Name, Comment, Version, `X-AppImage-Version`, Icon),
  extract icon → `~/.cache/libreapp-center/appimage-icons/<sha>.png`,
  `iconUrl` = that path ('' when extraction fails). Version fallback
  chain: `X-AppImage-Version` → `Version` → filename → null (research:
  never assume a version exists).
- `install(id)`: the adopt/integrate flow —
  1. Resolve sha256 → source path (re-scan if missing).
  2. If manifest exists for this sha256 → `Done(noop: true)`.
  3. If source is already inside `~/Applications` → integrate in place.
     Else copy → `~/Applications/<slug>.AppImage`, `chmod +x`,
     verify sha256 of the copy matches.
  4. Write `~/.local/share/applications/appimage-<slug>.desktop`
     (prefixed to avoid shadowing distro entries) with
     `X-LibreStore-*` provenance keys; extract icon to hicolor tree;
     write install manifest
     `~/.local/share/libreapp-center/appimage/<sha>.json`
     `{sourcePath, managedPath, copied: bool, desktopFile, iconPath}`.
  5. Handle states: `Preparing → Applying → Done`. Cancel during copy →
     delete partial copy → `Cancelled` (never bare `Failed`).
- `remove(id)`: read manifest → delete `.desktop`, icons, manifest.
  If `copied: true` → delete the managed copy too; else leave the
  user's original file untouched (de-integrate only). Unknown id →
  `AppNotFoundException`.
- `recoverInFlight()` → `[]` (file ops are short; nothing to re-attach).

**AppimageOperationHandle**: `StreamController<OperationState>`-backed,
`current` getter, `cancel()` → `Cancelling` → terminal within 2s.
Follows the legal transition DAG in `operation.dart`.

## 4. Identity

`AppIdentity(backendId: 'appimage', nativeId: <sha256 hex>)`.
Content-addressed: stable across moves/renames/copies; the install-copy
keeps the same identity. Filename is display-only.

## 5. Wiring & flags

- `packages/store_host/lib/src/flags.dart`: add
  `'backend.appimage.enabled': false` with ADR-010 comment
  (owner `libreapp-center`, removal `2027-06-30`).
- `packages/app_center/lib/store/store_host_wiring.dart`: register
  `BackendAppimage(transport: RealAppImageTransport())` (composition
  root only — the sanctioned boundary). `catalog.backend_order`
  unchanged in MVP (backend off by default; order is an explicit
  operator setting when enabling).
- `scripts/dep_trace.py`: must report zero new violations.

## 6. Testing strategy

- `runContractExam('appimage', …)` with stubbed transport:
  isAvailable <200ms, install→terminal, cancel mid-copy → terminal,
  unknown id → typed, idempotent install → `Done(noop: true)`,
  listInstalled shape, recoverInFlight `[]`.
- Unit: magic-byte classifier (type1/type2/garbage), filename
  heuristic parser, `.desktop` key parser, version fallback chain,
  manifest round-trip, desktop-file template rendering.
- No live system mutation in tests — stubbed filesystem/transport only.

## 7. Risks & honest limitations

- sha256 scan cost on huge collections: mitigated by
  (path,size,mtime) cache; first scan of a large `~/Downloads` is slow
  (documented; scan is off the UI critical path).
- `--appimage-extract` on a temp copy duplicates large files transiently;
  `unsquashfs` single-file path avoids it when present.
- `~/Downloads` in the default scan set: noisy but matches appimaged;
  documented, tunable later via a flag.
- Mounted-partition dirs excluded from MVP scan set.
- No live-CLI verification possible in sandbox (no AppImage fixtures
  with real binaries in tests — stubbed transports only, same as the
  other three backends).
