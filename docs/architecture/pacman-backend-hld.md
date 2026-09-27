# HLD: pacman backend (`packages/backend_pacman`)

Status: design locked (2026-09-27). Implements grandvision.md Phase 1
("more backends as plugins"). Research: `pacman-research.md` (man
pages / Arch wiki / mailing lists / polkit docs verified 2026-09-27;
no Arch box — every CLI shape is a reconstructed fixture, not a
live capture).

## 1. Goal

A `StoreBackend` plugin for pacman packages on Arch-like systems, over
a `pacman` CLI subprocess transport — the flatpak slice's proven
pattern (`CliFlatpakTransport`), adapted for pacman's wire shapes:
4-token `name;version;arch;repo` IDs with opaque versions, pkexec
privilege elevation, `checkupdates`/`-Qu` update checks, name-keyed
card identity. The host thesis holds: "one app, one card — the format
is a detail." This slice is the backend plugin only. No cross-format
identity merging (deferred to Phase 3 per HLD v1 grouping policy); no
UI changes beyond the composition root and the platform seed table.

## 2. Non-goals

- Enabling the backend anywhere except arch-like seeding:
  `backend.pacman.enabled` defaults OFF; `seedPlatformBackendDefaults`
  turns it ON for `isArchLike` (research D11 — explicitly decided,
  not deferred).
- AUR support (research §5 — out of scope; no AUR-helper
  subprocesses, ever, in this slice).
- libalpm FFI (research §1 — rejected: no Dart binding exists, and a
  child process is the only cancel-safe vehicle).
- Per-operation `pacman -Sy` (partial-upgrade doctrine —
  research §7).
- `-Rs` cascade remove (MVP is `-R`; the cascade needs its own UX
  decision — research §10.1).
- AppStream icons. `iconUrl` = `''` in MVP, same as deb/rpm (no icon
  source in pacman's CLI surface).
- Fixing anything in the other backends.

## 3. Architecture

```
packages/backend_pacman/
  lib/backend_pacman.dart         # barrel: backend, identity helpers
  lib/testing.dart                # StubPacmanTransport (tests only)
  lib/src/transport.dart          # PacmanTransport (injectable seam) +
                                  #   PacmanPackageId, PacmanPackageData,
                                  #   tx event types, PacmanProcess
  lib/src/cli_transport.dart      # CliPacmanTransport (Process.start)
  lib/src/backend.dart            # BackendPacman extends StoreBackend
  lib/src/handle.dart             # PacmanOperationHandle
  lib/src/metadata.dart           # version display, size parsing
  lib/src/identity.dart           # package-id parse/validate, card key
  test/exam_test.dart            # runContractExam + unit tests
```

All outside-world contact (child processes) goes through
`PacmanTransport`, mirroring the flatpak backend's ADR-006 pattern.
Tests script a stub; production uses `CliPacmanTransport`.

### Interface contracts

**PacmanTransport** — the only impure seam (plain Dart, no `Process`
types leak past it; mirrors `FlatpakTransport` run/spawn/terminate):

- `checkAvailable()` — throw `PacmanTransportException` when the
  `pacman` binary is missing/unusable. Probe: `pacman --version`
  within the 200ms contract budget (research §2.10).
- `hasCheckupdates()` — cached bool: is the `checkupdates` binary
  present (research §2.6).
- `search(String query)` → `List<PacmanPackageData>` — one
  `pacman -Ss -- <escaped>` invocation; parse header blocks
  (research §2.2). Query is escaped to a literal regex (research D12).
- `getDetails(String packageId)` → `PacmanPackageData` —
  `pacman -Si -- <name>`, post-filter on `Name:`; fallback
  `pacman -Qi -- <name>` for foreign/AUR-installed packages
  (research §2.3–2.4). Throw `PacmanNotFoundException` when neither
  finds it.
- `installedPackages()` → `List<PacmanPackageData>` — **one**
  `pacman -Q` invocation, parsed line-wise (research §2.1, D3). Skip
  unparseable lines (never fail the whole list); throw
  `PacmanTransportException` only when the invocation itself fails.
  No legacy N+1 path: the bulk call *is* the only path
  (bulk-installed.md — the per-package `-Qi` enumeration is dead).
- `isInstalled(String name)` → `bool` — `pacman -Q -- <name>`:
  exit 0 → true; exit 1 (+ `was not found`) → false. The noop-check
  primitive.
- `updatesAvailable()` → `List<PacmanPackageData>` — `checkupdates`
  when present (exit 0 → parse, 2 → `[]`, 1 → typed error), else
  `pacman -Qu` with the exit-code quirk handled by stdout/stderr
  inspection (research §2.5–2.6, D5). Each entry carries old→new
  (`installedVersion` = old, `version` = new).
- `install(packageId)` / `remove(packageId)` / `update(packageId)` →
  `PacmanTransaction` — spawn `pkexec pacman -S --needed --noconfirm
  -- <repo/name>` / `pkexec pacman -R --noconfirm -- <name>` /
  `pkexec pacman -S --noconfirm -- <name>`; the child process's line
  stream drives the handle (research §4, §2.7). `repo/name` pinning
  when repo is known, bare name otherwise (research D2).

**PacmanPackageId** (transport-level):

- Parses `name;version;arch;repo` (4 tokens). `version` is **opaque**
  (`epoch:pkgver-pkgrel` carried verbatim — research §3).
- Card key: **the name alone** (research §3 — alpm's local db is
  name-keyed; no multi-arch cards, unlike rpm).

**BackendPacman** (`id: 'pacman'`, `contractVersion: storeContractsMajor`):

- `capabilities = {search, details, install, remove, update,
  permissions}`.
  - `permissions` = the unsandboxed disclosure (pacman packages run
    unsandboxed — ADR-009, same as deb/rpm; research D9).
  - No `ratings` (ADR-005).
- `isAvailable()`: `checkAvailable()` within the 200ms contract
  budget; never throws.
- `listInstalled()`: `installedPackages()` → `AppInfo` per line
  (name, installed version; summary `''` — descriptions are a
  `getDetails()` concern, never an N+1 in the list path). Every entry:
  `AppSource.pacman` (**never `deb`** — research D10),
  `isInstalled == true`. A failed invocation → mapped `StoreException`
  (host contract: partial results, never throw — here "partial" is
  the skip-unparseable-lines rule; total failure is a real error).
- `search(query)`: stream of `AppInfo` over `transport.search()`;
  cancellable via the subscription (killing the `pacman -Ss` child is
  the honest bound of "stop work" — satisfies the 500ms rule, same as
  flatpak).
- `getDetails(id)`: parse id → `transport.getDetails()` → `AppDetails`
  (description, license, homepage, install/download sizes kept on the
  data object; `permissions` = unsandboxed disclosure).
- `install(app)`: no-op (`Done(noop: true)`) when `isInstalled(name)`;
  else a `PacmanOperationHandle` over the pkexec child. `--needed`
  makes the child itself idempotent as belt-and-braces.
- `remove(app)`: no-op when not installed; else the `-R` handle.
- `update(app)`: consult `updatesAvailable()`; if the name is not in
  the update list → `Done(noop: true)` without spawning; else the
  `-S` handle.
- `checkUpdates()`: `updatesAvailable()` → `UpdateInfo` list with
  `fromVersion` (old) → `toVersion` (new).
- `recoverInFlight()` → `[]` — pacman has no in-flight transaction
  journal the backend could re-attach to (no snapd-like `Doing`
  query). Honest; the exam tolerates empty.

**PacmanOperationHandle**: mirrors `FlatpakOperationHandle` (the CLI
sibling) — `StreamController<OperationState>`-backed, `current`
getter, `cancel()` → `cancelling` within 2s, 60s heartbeat re-emit
during `downloading`/`applying` (operation-state-machine.md §4;
stall-watchdog.md §1), DAG-legal emissions only. Phase mapping from
pacman line events (research §2.7):

| pacman output | Phase |
|---|---|
| spawned, no output yet (pkexec prompt in flight) | `Authenticating` |
| `resolving dependencies…`, `Packages (N)…`, `Total … Size:` | `Preparing` |
| `:: Retrieving packages…`, `<file> downloading…` | `Downloading` (bytesTotal from `Total Download Size:`, bytesDone indeterminate — research §2.8) |
| `checking keyring…`, `checking package integrity…` | `Verifying` |
| `(N/M) installing\|upgrading\|removing …`, `:: Processing package changes…`, `:: Running post-transaction hooks…` | `Applying` (fraction `N/M` when markers seen, else indeterminate) |
| pkexec exit 126 | `Failed(AuthException(dismissed))` — quiet |
| child killed by our cancel | `Cancelled` (never `Failed` — §3 race rule) |
| child exit 0 after cancel requested | `Done(cancelRequested: true)` |

- `cancel()`: prompt `cancelling` ack within 2s, then
  `SIGTERM` → 2s grace → `SIGKILL` on the child (flatpak's
  `terminate()` shape). The terminal state follows the child's exit;
  a mid-apply kill is documented as non-atomic (research §8).
- One mutating operation per backend at a time is already the engine
  default (`engine.max_concurrent_per_backend = 1`); for pacman it is
  load-bearing (the db lock `/var/lib/pacman/db.lck` serializes
  anyway) — a second concurrent mutate would hit `could not lock
  database` → `ConflictException`.

## 4. Identity

`AppIdentity(backendId: 'pacman', nativeId: <verbatim package-id>)`.

- `nativeId` = `name;version;arch;repo` as parsed at the transport
  seam — opaque to the backend above the transport layer. `repo`/`arch`
  may be empty when the id came from the `-Q` path (no repo column
  there); the transport fills them when known (search/details paths).
- Card key = **name**. The transport owns the parse; the backend never
  splits the version.
- Display: name shown bare; version shown verbatim (`1:28.5.1-1`
  included — never prettified, epoch included).

## 5. Wiring & flags

- `packages/store_contracts/lib/src/identity.dart`: add `pacman` to
  `AppSource`. **Labeling honesty rule: pacman results must never be
  labeled `deb`** (research D10; platform-detection.md's Fedora
  lesson).
- `packages/store_host/lib/src/flags.dart`: add
  `'backend.pacman.enabled': false` with ADR-010 comment
  (owner `libreapp-center`, removal `2027-06-30`). Default OFF.
- `packages/store_host/lib/src/platform_detection.dart`:
  `seedPlatformBackendDefaults` gains: `if (platform.isArchLike)
  flags.seedDefault('backend.pacman.enabled', true)` (research D11 —
  decided here; the pacman probe only passes where pacman exists, so
  this is safe, unlike rpm's deferred seeding).
- `packages/app_center/lib/store/store_host_wiring.dart`: register
  `BackendPacman(transport: CliPacmanTransport())`
  (composition root only — the sanctioned boundary).
  `catalog.backend_order` unchanged in this slice.
- `scripts/dep_trace.py`: must report zero new violations.

## 6. Testing strategy

- `runContractExam('pacman', …)` with stubbed transport:
  isAvailable <200ms, install→terminal, cancel mid-transaction →
  terminal, unknown id → typed, idempotent install → `Done(noop:
  true)`, listInstalled shape, recoverInFlight `[]`.
- Unit: 4-token ID parser (accepts 4, rejects 3/5/garbage; version
  carried verbatim incl. epoch forms; verbatim round-trip),
  `-Q`/`-Ss`/`-Si`/`-Qu` line parsers against the §2 fixtures,
  `checkupdates` exit-code mapping (0/1/2), pkexec 126/127 mapping,
  `-Qu` exit-1-with-empty-stdout → `[]`, error-pattern table.
- The stub emits the research §2 fixtures verbatim — the stub is the
  contract that the real pacman speaks those shapes. Scripted
  transactions pace line events so the handle and the exam's cancel
  test observe each phase.
- No live system mutation in tests — stubbed transport only, same as
  the other backends. No Arch box exists in CI either; the fixtures
  are the executable spec until dogfood.

## 7. Risks & honest limitations

- **No live pacman verification possible in sandbox** (Ubuntu, no
  pacman binary): every wire claim is reconstructed from cited
  sources. The first Arch dogfood run must re-verify §2 line by line;
  fixture drift is expected and is a fixture fix, not a design fix.
- **Cancel is not atomic** (research §8): killing pacman mid-apply
  can leave a half-configured system; the next `-Su` repairs it. This
  is the deepest architectural difference from the PackageKit
  backends — stated, not hidden.
- **Download progress is indeterminate in MVP** (research §2.8):
  piped pacman prints no byte-true progress; the UI shows phase +
  heartbeat, not a fabricated bar. `-Sp` planning is the recorded
  future lever.
- **`checkupdates` needs pacman-contrib** (not a default install):
  without it, `checkUpdates()` falls back to raw `-Qu` with the stale-db
  caveat (research §7). The backend never runs `-Sy` itself.
- **pkexec needs polkit + a session agent** (research §4): without
  them, mutating operations fail typed. The store shows no password
  dialogs of its own (contract rule).
- **`update()` does a full `checkUpdates()` for its noop check** —
  one fakeroot sync per update call when `checkupdates` is present.
  Acceptable for v1 (updates are user-initiated, not polled through
  this path); the poll path uses the host fan-out with its own 30s
  budget.
- `iconUrl` is `''`; AUR is out of scope (§2); `-Rs` is a future
  decision.
