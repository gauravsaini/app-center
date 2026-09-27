# HLD: RPM backend (`packages/backend_rpm`)

Status: design locked (2026-09-27). Implements grandvision.md Phase 1
("more backends as plugins"). Research: `rpm-research.md` (PackageKit
source-verified 2026-09-27; no Fedora box — claims are source- or
doc-cited, never live-measured).

## 1. Goal

A `StoreBackend` plugin for RPM packages on Fedora-like systems, over
PackageKit D-Bus against the dnf5 backend — the same D-Bus roles the
deb backend uses, adapted for rpm semantics: 5-token package IDs,
(name, arch) card identity, solver-based updates. The host thesis
holds: "one app, one card — the format is a detail." This slice is the
backend plugin only. No cross-format identity merging (deferred to
Phase 3 per HLD v1 grouping policy); no UI changes beyond the
composition root.

## 2. Non-goals

- Enabling the backend anywhere: `backend.rpm.enabled` defaults OFF;
  platform seeding to enable it on fedora-like systems is a separate
  future decision (research D8). The backend ships dark.
- AppStream icons (no icon field on the PackageKit D-Bus surface;
  research §7). `iconUrl` = `''` in MVP, same as deb.
- `dnf` CLI subprocesses (research D10): all traffic goes over D-Bus.
- Per-operation `RefreshCache` (auth-gated; daemon owns metadata
  freshness).
- Fixing the deb backend's latent 5-token ID bug (flagged in research
  D1; separate follow-up slice, not this one).

## 3. Architecture

```
packages/backend_rpm/
  lib/backend_rpm.dart           # barrel: backend, identity helpers
  lib/testing.dart               # StubRpmTransport (tests only)
  lib/src/transport.dart         # RpmTransport (injectable seam) +
                                 #   RpmPackageId, RpmPackageData,
                                 #   tx event types
  lib/src/packagekit_transport.dart  # RealRpmPackageKitTransport
  lib/src/backend.dart           # BackendRpm extends StoreBackend
  lib/src/handle.dart            # RpmOperationHandle
  lib/src/metadata.dart          # version display, name/arch helpers
  lib/src/identity.dart          # package-id parse/validate, card key
  test/exam_test.dart            # runContractExam + unit tests
```

All outside-world contact (D-Bus) goes through `RpmTransport`,
mirroring the deb backend's ADR-006 pattern. Tests script a stub;
production uses `RealRpmPackageKitTransport`.

### Interface contracts

**RpmTransport** — the only impure seam (plain Dart, no D-Bus types
leak past it):

- `checkAvailable()` — throw `RpmTransportException` when the daemon
  is unreachable. Probe: create a throwaway transaction (never given
  an action; the daemon reaps idle transactions) — same as deb.
- `search(String query)` → `List<RpmPackageData>` — one `SearchNames`
  transaction with the **arch filter** (native arch + noarch;
  research D3).
- `getDetails(String packageId)` → `RpmPackageData` — resolve
  (name, arch) fresh, then one `GetDetails` transaction. Throw
  `RpmNotFoundException` for unknown packages.
- `installedNames()` → `List<String>` of package-ids (legacy path).
- `installedPackages()` → `List<RpmPackageData>` — bulk:
  `GetPackages({installed})` + one batched `GetDetails`; dedupe by
  **(name, arch)** (research D2/D5). Throw `RpmTransportException`
  when the batch fails; the backend falls back to the per-package
  path.
- `updatesAvailable()` → `List<RpmPackageData>` — one `GetUpdates`
  transaction; each entry carries the *update* package-id and the
  installed EVR for `fromVersion` (research D5).
- `install(packageId)` / `remove(packageId)` / `update(packageId)` →
  `RpmTransaction` — re-resolve (name, arch) at mutate time, then the
  D-Bus mutate role on a dedicated transaction whose event stream
  drives the handle (research D4).

**RpmPackageId** (transport-level, tolerant):

- Parses `name;evr;arch;origin;data` (5 tokens). Never uses
  `package:packagekit`'s strict 4-token `fromString` (research D1).
- `evr` is **opaque**: stored and compared verbatim, never split
  into epoch/version/release (epoch 0 is omitted by the backend —
  string surgery would corrupt identity).
- Card key: `(name, arch)`.

**BackendRpm** (`id: 'rpm'`, `contractVersion: storeContractsMajor`):

- `capabilities = {search, details, install, remove, update,
  permissions}`.
  - `permissions` = the unsandboxed disclosure (RPMs run unsandboxed
    — same honesty as debs, ADR-009; research D6).
  - No `ratings` (ADR-005).
- `isAvailable()`: `checkAvailable()` within the 200ms contract
  budget; never throws (cold daemon reads unavailable on first probe).
- `listInstalled()`: bulk first (`installedPackages()`), degrade to
  the legacy per-package path on batch failure — the host contract is
  partial results, never throw. Every entry: `AppSource.rpm`
  (**never `deb`** — research D7), `installedVersion` = installed
  EVR, `isInstalled == true`.
- `search(query)`: stream of `AppInfo` over the arch-filtered
  `SearchNames` results; cancellable via the subscription (abandoning
  the transaction is the honest bound of "stop work", same as deb).
- `getDetails(id)`: resolve → `GetDetails` → `AppDetails`
  (description, license or `"unknown"`, homepage url, install size;
  download size documented as wire-available but unsurfed —
  research §7).
- `install(app)`: no-op (`Done(noop: true)`) when the (name, arch) is
  already installed; else a `RpmOperationHandle` over the D-Bus
  transaction.
- `remove(app)` / `update(app)`: handles over D-Bus transactions.
- `checkUpdates()`: `updatesAvailable()` → `UpdateInfo` list with
  `fromVersion` (installed EVR) → `toVersion` (update EVR).
- `recoverInFlight()` → `[]` — same honesty as deb: a raw
  transaction path cannot be reliably mapped back to (package,
  operation). The exam tolerates empty.

**RpmOperationHandle**: mirrors `DebOperationHandle` exactly —
`StreamController<OperationState>`-backed, `current` getter,
`cancel()` → `cancelling` within 2s, 60s heartbeat re-emit during
`downloading`/`applying` (stall-watchdog.md §1), DAG-legal emissions
only, PackageKit phases mapped (`download*` → `Downloading`,
`install`/`remove`/`update` → `Applying`, `signatureCheck` →
`Verifying`, else `Preparing`). Follows the legal transition DAG in
`operation.dart`.

## 4. Identity

`AppIdentity(backendId: 'rpm', nativeId: <verbatim package-id>)`.

- `nativeId` is the full package-id string as emitted by the daemon
  (`name;evr;arch;origin`) — opaque to the backend above the
  transport layer.
- Display name = package name; the UI card key is (name, arch):
  `firefox.x86_64` and `firefox.i686` are separate cards (research
  §5). The transport owns the name/arch split; the backend never
  parses the EVR.

## 5. Wiring & flags

- `packages/store_contracts/lib/src/identity.dart`: add `rpm` to
  `AppSource`. **Labeling honesty rule: rpm results must never be
  labeled `deb`** — the Manage page groups by source, and
  fedora-like systems have deb disabled by platform seeding; a
  mislabeled rpm row would be invisible-or-wrong there.
- `packages/store_host/lib/src/flags.dart`: add
  `'backend.rpm.enabled': false` with ADR-010 comment
  (owner `libreapp-center`, removal `2027-06-30`). Default OFF —
  the backend ships dark.
- `packages/app_center/lib/store/store_host_wiring.dart`: register
  `BackendRpm(transport: RealRpmPackageKitTransport())`
  (composition root only — the sanctioned boundary).
  `catalog.backend_order` unchanged in this slice (backend off by
  default; order is an explicit operator setting when enabling).
- **Explicitly deferred:** platform seeding that enables
  `backend.rpm.enabled` on fedora-like systems (research D8). That is
  a separate decision with its own slice — this HLD documents the
  deferral, it does not implement it.
- `scripts/dep_trace.py`: must report zero new violations.

## 6. Testing strategy

- `runContractExam('rpm', …)` with stubbed transport: isAvailable
  <200ms, install→terminal, cancel mid-transaction → terminal,
  unknown id → typed, idempotent install → `Done(noop: true)`,
  listInstalled shape (incl. multi-arch entries as separate cards),
  recoverInFlight `[]`.
- Unit: 5-token ID parser (accepts 5, rejects 4/6/garbage; EVR
  untouched), (name, arch) dedupe, arch-filter constant, bulk-merge
  incl. the "batch fails → legacy path" degradation, error mapping.
- The stub emits **5-token IDs** (`name;evr;arch;origin;installed`)
  — the stub is the contract that the real backend speaks the
  dnf5 wire shape (research §10).
- No live system mutation in tests — stubbed transport only, same as
  the other four backends.

## 7. Risks & honest limitations

- **No live D-Bus verification possible in sandbox** (no Fedora box):
  every wire claim is source-read from the PackageKit repo, not
  measured. The first Fedora dogfood run must re-verify the ID shape,
  the arch-filter behavior, and the polkit prompt path.
- The 5-token parser is load-bearing: if a future PackageKit changes
  the ID shape, parsing fails closed (typed error, never a corrupt
  identity).
- `GetUpdates` freshness depends on the daemon's metadata cache; no
  per-op refresh in MVP (auth-gated) — a stale update list is
  possible, documented.
- `iconUrl` is `''` (no icons on the D-Bus surface); AppStream icons
  are a post-MVP subsystem.
- Download size is wire-available but unsurfed by the MVP transport
  (Dart client only reads `size`); surfaced later with the tolerant
  parser (research D1 already requires transport-level parsing, so
  this is a small follow-up).
- The deb backend's latent 5-token bug (research D1) is NOT fixed in
  this slice — separate follow-up.
