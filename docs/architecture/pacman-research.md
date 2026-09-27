# pacman backend — transport research

**Status:** research leaf, read-only. No implementation code written.
**Branch:** `feat/backend-pacman` · **Package:** `packages/backend_pacman` (to be created)
**Parent docs:** [hld.md](hld.md), [lld.md](lld.md), [host-wiring.md](host-wiring.md),
[operation-state-machine.md](operation-state-machine.md),
[platform-detection.md](platform-detection.md)
**Pattern to follow:** `packages/backend_{snap,deb,flatpak}` — all outside-world
contact goes through an injectable `Transport`; tests script a stub
(see `packages/backend_flatpak/lib/src/transport.dart` for the CLI-subprocess
precedent this slice follows).

This note answers, with verified evidence, what the pacman transport can
and cannot rely on. Every behavioral claim below is cited to a live source
(pacman man pages, Arch wiki, pacman/pacman-contrib mailing lists, polkit
docs, or a real-world pacman-CLI consumer). **Nothing here was measured on an
Arch box — the sandbox is Ubuntu, no pacman binary exists here — so every
claim names its source**, and every CLI output shape is marked
"fixture: reconstructed from cited sources, not live-captured". The design
decisions it forces are collected in §9.

---

## 1. Transport options: CLI subprocess vs libalpm FFI

### Option (a): `pacman` CLI subprocess — CHOSEN

All reads and mutates shell out to the `pacman` binary, exactly as
`backend_flatpak` shells out to the `flatpak` binary
(`CliFlatpakTransport`: `Process.start`, line-split stdout/stderr,
`SIGTERM`→2s-grace→`SIGKILL` terminate). The backend parses pacman's
textual output at the transport seam; the stub transport serves the
fixtures in §2.

### Option (b): libalpm C bindings via Dart FFI — REJECTED

Verification (2026-09-27): no Dart libalpm binding exists. Evidence —
pub.dev search for `alpm`/`pacman` returns no binding package, and the
GitHub `alpm` topic lists bindings for **Rust, Go, Vala, Python, C++ —
no Dart**. A binding would have to be written from scratch with
`package:ffigen` against vendored libalpm headers, then maintained
across libalpm ABI drift.

Rejection reasons:

1. **No binding to reuse** (verified above) — the FFI path starts at
   zero, while the CLI path starts at a proven in-repo precedent
   (flatpak).
2. **Memory-safety surface.** libalpm is a C library with manual memory
   management; every call crosses an FFI boundary the Dart side cannot
   verify. A subprocess crash is a typed `PacmanCommandException`; an
   FFI misuse is a segfault that takes the whole store down.
3. **Process isolation.** A hung or wedged `pacman -S` can be
   `SIGTERM`ed/`SIGKILL`ed from Dart; a wedged FFI call blocks the
   isolate with no kill switch. The 2s cancel-ack rule
   (operation-state-machine.md §3) is only implementable against a
   child process.
4. **pacman is the canonical client.** pacman(8) *is* libalpm's
   reference frontend; its CLI output shapes are stable, documented,
   and consumed by real tooling (e.g. `checkupdates`, and third-party
   stores that parse `-Si`/`-Sp` output — see §2.7). There is no
   privileged D-Bus daemon for pacman on Arch (no PackageKit
   equivalent by default), so the CLI is not a fallback — it is the
   interface.

**Q1 verdict:** CLI subprocess. The transport is `CliPacmanTransport`
over `Process.start`, mirroring `CliFlatpakTransport` line for line
(run/spawn/terminate semantics).

---

## 2. CLI output shapes (fixtures)

All fixtures below are **reconstructed from cited sources, not
live-captured** (no Arch box in the sandbox). The implementation leaf
must treat them as *candidate* fixtures and re-verify each on first
dogfood; the exam scripts the stub with exactly these shapes, so any
drift found live is a fixture fix, not a design fix.

### 2.1 `pacman -Q` — bulk installed enumeration (single invocation)

`pacman -Q` with no args prints every installed package, one per line:
`name<space>version`. Package names cannot contain spaces; the version
is `pkgver-pkgrel` with an optional `epoch:` prefix. (Arch wiki —
"Querying package databases"; kbmisc pacman listing guide.)

```
firefox 146.0-1
glibc 2.42+r12+g7d1e6f5f3b0-1
docker 1:28.5.1-1
linux 6.16.8.arch1-1
yay 12.5.2-1
```

Notes for the parser:

- Split on the **first space**; the remainder is the version verbatim
  (versions never contain spaces — verified against the PKGBUILD
  `pkgver`/`pkgrel` character rules).
- `docker 1:28.5.1-1` shows the **epoch prefix** (`1:`) — the version
  is opaque, carried verbatim, never split (same lesson as the rpm
  EVR, rpm-research.md §1.2).
- `-Q` never emits a repo or arch column. The ID built from this path
  leaves `arch`/`repo` empty (HLD §4 — card key is the name alone).
- `pacman -Q <name>` (explicit names) prints only those packages and
  exits **1** with `error: package '<name>' was not found.` on stderr
  when a name is unknown — this is the installed-check primitive
  (`_isInstalled`), not a bulk path.

### 2.2 `pacman -Ss <regex>` — search

Searches **name and description** in the sync databases (Arch wiki —
"Querying package databases"). Every argument is a **POSIX regex**
(pacman(8)); the transport escapes user input (`RegExp.escape`) so a
store search is literal. Block shape: a header line
`repo/name version [flags…]` followed by one or more indented
description lines. Fixture (shape after the Atlantic.net `-Ss docker`
capture and the Manjaro `-Qs` capture):

```
extra/firefox 146.0-1 [installed]
    Standalone web browser from mozilla.org
extra/firefox-i18n-de 146.0-1
    German language pack for Firefox
    Provides translations for menus, dialogs and help pages
multilib/wine 10.0-1
    A compatibility layer for running Windows programs
```

Parser rules:

- Header regex: `^([^/\s]+)/([^\s]+)\s+([^\s]+)(?:\s+\[(.*)\])?$` —
  repo, name, version, optional bracket flags.
- `[installed]` marks an installed package (the sync-db version is
  shown; the installed version comes from `-Q` if needed). The parser
  accepts *any* `[...]` suffix as "installed" and does not interpret
  its contents (a possible `[installed: x.y-z]` long form is noted
  as to-verify on dogfood — HLD §7).
- Description = all following lines starting with whitespace, joined
  with `\n`, until the next header or EOF. Descriptions **wrap** (see
  `firefox-i18n-de`); the parser must join continuation lines, not
  take only the first.
- Stderr on a broken/unsynced db is empty output with exit 0 — stale
  results, not an error (§7).

### 2.3 `pacman -Si <name>` — sync-db details

One info block per package; blocks separated by a blank line (the
multi-package form is what `pacman -Si a b` emits; tux_store's
PACMAN_MANAGER.md splits on `"\n\n"` — same rule). Field lines are
`Key : value`; continuation lines start with two spaces. Fixture
(shape after the Atlantic.net `-Si nginx` capture):

```
Repository      : extra
Name            : nginx
Version         : 1.29.1-1
Description     : Lightweight HTTP server and IMAP/POP3 proxy server
Architecture    : x86_64
URL             : https://nginx.org
Licenses        : custom
Groups          : None
Provides        : None
Depends On      : pcre2  zlib  openssl  geoip  mailcap  libxcrypt
Optional Deps   : None
Conflicts With  : None
Replaces        : None
Download Size   : 585.77 KiB
Installed Size  : 1693.74 KiB
Packager        : Giancarlo Razzolini <grazzolini@archlinux.org>
Build Date      : Fri 10 Jun 2022 01:45:12 PM UTC
Validated By    : MD5 Sum  SHA-256 Sum  Signature
```

Fields the backend reads: `Repository`, `Name`, `Version`,
`Description`, `Architecture`, `URL`, `Licenses`, `Download Size`,
`Installed Size`. Size format is `%.2f <unit>` with units
`B/KiB/MiB/GiB` (pacman-dev patches on `humanize_size`; tux_store
parses case-insensitively — same rule here). `-Si` arguments are
regexes too; the transport **post-filters on `Name: == <requested>`**
and treats no exact block as not-found. Unknown name: exit 1, empty
stdout, stderr `error: package '<name>' was not found` (same shape as
`-Q`; fixture marks it as reconstructed).

### 2.4 `pacman -Qi <name>` — local-db details (fallback)

Same block shape as `-Si` minus `Repository`/`Download Size` (local
db has no download size; `Installed Size` present). Used as the
**fallback** when `-Si` finds nothing — this is how an AUR/foreign
installed package still gets an honest details page in Manage
(tux_store uses the same `-Si`-then-`-Qi` cascade). Install from this
path is never offered (the package is not in any sync db).

### 2.5 `pacman -Qu` — updates (fallback when `checkupdates` absent)

One line per updatable package: `name oldver -> newver`. (pacman
Rosetta; checkupdates.sh.in pipes exactly this shape.) Exit-code
quirk, verified from the pacman-contrib mailing list ("stick with
exit 1 for compatibility with `pacman -Qu`"): **`-Qu` exits 1 both
when there are no updates AND on real errors** — so the transport
never maps exit code alone. Rule: exit 0 + lines → updates; exit 1 +
empty stdout → no updates (normal); exit 1 + stderr text → typed
error. Lines containing `[...]` are dropped (checkupdates applies
`grep -v '\[.*\]'` to strip ignored-package markers — same filter).

```
firefox 146.0-1 -> 146.0.2-1
glibc 2.42+r12+g7d1e6f5f3b0-1 -> 2.43+r1+gdeadbeef-1
```

### 2.6 `checkupdates` — updates (preferred)

From `pacman-contrib` (not installed by default — the transport probes
for the binary once and caches the answer). What it does
(checkupdates.sh.in, verified from the mailing-list patches):

1. `fakeroot -- pacman -Sy --dbpath <tmp>` — syncs into a **temporary
   db**, no root needed, **no lock on the real db**.
2. `pacman -Qu --dbpath <tmp> | grep -v '\[.*\]'` — same line shape as
   §2.5.

Exit codes (CHANGES.md / accepted patches, current pacman-contrib):

| Code | Meaning |
|---|---|
| `0` | updates printed on stdout (§2.5 shape) |
| `2` | no updates available (normal, not an error) |
| `1` | failure — e.g. `Cannot fetch updates` (network), missing `fakeroot` |

The transport maps 2 → empty list, 1 → typed error from stderr text.
**This is why it is preferred over raw `-Qu`:** it does its own safe
sync, so `checkUpdates()` never reads a stale db and never needs root.

### 2.7 `pacman -S --noconfirm <pkg>` — install/upgrade transaction

With `--noconfirm`, pacman prints the transaction summary and walks
straight past the prompt into the transaction (verified: johanx22x
dotfiles research asked a real pacman in a throwaway root; the
archinstall log shows the full non-TTY sequence). Fixture
(reconstructed from the archinstall issue log + msys2 `--noconfirm`
capture):

```
resolving dependencies...
looking for conflicting packages...

Packages (2) libutil-linux-2.41.2-1  util-linux-2.41.2-1

Total Download Size:   1.71 MiB
Total Installed Size:  9.63 MiB
Net Upgrade Size:       2.10 MiB

:: Proceed with installation? [Y/n]
:: Retrieving packages...
 archinstall-3.0.5-1-any downloading...
checking keyring...
checking package integrity...
loading package files...
checking for file conflicts...
checking available disk space...
:: Processing package changes...
installing archinstall...
:: Running post-transaction hooks...
(1/1) Arming ConditionNeedsUpdate...
```

Phase markers for the handle (LLD §5):

- `Total Download Size: <size>` → `bytesTotal` for the download phase
  (absent when everything is cached → `bytesTotal: null`,
  indeterminate).
- `:: Retrieving packages...` + `<file> downloading...` lines →
  `downloading` (these per-file lines are what pacman prints when the
  progress bar is off — see §2.8).
- `checking keyring...` / `checking package integrity...` →
  `verifying`.
- `(N/M) installing|upgrading|removing <name>` →
  `applying(fraction: N/M)` — monotonic, real, never fabricated.
- `:: Processing package changes...` / `:: Running post-transaction
  hooks...` → `applying` (indeterminate when no `(N/M)` seen yet).
- Everything before the summary (`resolving dependencies...`,
  `looking for conflicting packages...`, the `Packages (N)` list) →
  `preparing`.
- Remove transactions print `removing <name>...` lines under the same
  `:: Processing package changes...` banner; same mapping.

### 2.8 Progress bars when piped — what we actually get

pacman turns off interactive progress bars when stdout is a pipe, not
a TTY (Arch forums — "the common practice is to turn off interactive
features (such as progress bars) when the output is to a pipe"). The
man page documents `--noprogressbar` as "useful for scripts that call
pacman and capture the output" — i.e. scripts are expected to cope
*without* bars. Consequences for the transport, stated honestly:

- **Do not expect `[###…] NN%` bars.** The per-file ` downloading...`
  lines (§2.7) are the download liveness signal; the 60s heartbeat
  re-emit (operation-state-machine.md §4) is the liveness guarantee
  when even those go quiet on a slow mirror.
- `bytesDone` during download has **no honest source** without the
  bars: the transport emits `Downloading(bytesDone: 0, bytesTotal:
  <parsed-or-null>)` and re-emits on liveness. A future `-Sp`
  planning step (tux_store's `pacman -Sp --print-format "%n|%s"`
  resolver-plan pattern, §2.9) could weight per-file completions —
  documented as a future lever, **not MVP** (one more subprocess per
  op; the honest-indeterminate download is acceptable for v1).
- `(N/M)` markers survive piping (they are plain lines, seen in
  non-TTY logs), so `applying` gets a real fraction.

### 2.9 Documented future lever: `pacman -Sp --print-format`

`pacman -Sp --print-format "%n|%s" <pkg>` runs pacman's **real
resolver** in print-only mode: package names + download sizes for the
whole transaction, root-free for explicit package names (emrac's
CHANGELOG verified live that `-S <pkg> --print` stays root-free while
`-Syu --print` does not, because `-y` enforces the root check). Not
MVP — the transport does not pre-plan; it parses the live
transaction. Recorded so the byte-true download bar has a known path.

### 2.10 `pacman --version` — availability probe

```
Pacman v7.1.0 - libalpm v15.0.0
```
Exit 0, root-free, no side effects. The `isAvailable()` probe
(200ms budget, never throws). Fixture marks the version string as
illustrative.

---

## 3. Identity and versions: `epoch:pkgver-pkgrel`, opaque

- pacman versions are `pkgver-pkgrel` with an optional `epoch:` prefix
  (`1:28.5.1-1`). Like the rpm EVR (rpm-research.md §1.2), the version
  string is **opaque**: carried verbatim, never split, never
  compared by string surgery.
- The backend never compares versions itself: `checkUpdates()` gets
  `old -> new` pairs from `-Qu`/`checkupdates`, and `update()` consults
  that list for its noop check. No `vercmp` reimplementation.
- Card key: **the package name alone** (HLD §4). Rationale: alpm's
  local db is keyed by name (`/var/lib/pacman/local/<name>-<version>/`)
  — two arches of the same name cannot be installed simultaneously,
  and Arch's multilib uses *renamed* packages (`lib32-*`), not
  same-name multi-arch. This differs deliberately from rpm's
  (name, arch) cards (rpm-research.md §5).

---

## 4. Privilege model — DECIDED: `pkexec` per operation

`-S`/`-R` need root. pacman has no polkit-aware daemon on Arch by
default (unlike Fedora's PackageKit), so the privilege vehicle must be
chosen explicitly. Decision, with the honest tradeoffs:

**DECIDED: mutating operations spawn `pkexec pacman …`.**

- `install`: `pkexec pacman -S --needed --noconfirm -- <repo/name>`
- `remove`: `pkexec pacman -R --noconfirm -- <name>`
- `update`: `pkexec pacman -S --noconfirm -- <name>`

Why pkexec and not the alternatives:

| Alternative | Verdict | Reason |
|---|---|---|
| `sudo -n pacman` | Rejected | Requires the user to have pre-configured NOPASSWD sudo; `-n` fails fast otherwise with no recourse. The store cannot configure sudo itself, and a graphical prompt is friendlier than a setup prerequisite. |
| Whole app launched as root | Rejected | A Flutter desktop app running as root is a non-starter (file pickers, network, WebViews all elevated; violates store_contracts "Backends MUST NOT …" spirit and every distro guideline). |
| Custom polkit helper / D-Bus service | Rejected for MVP | Correct long-term shape (a `org.libreappstore` action with a narrow policy), but it is a packaging + policy-file deliverable, not a transport decision. Recorded as the v2 path (HLD §7). |
| **pkexec per operation** | **Chosen** | No sudo pre-configuration; the polkit **session agent** shows the graphical prompt; per-call auth matches the `authenticating` operation phase honestly. Precedent: other system tools re-exec through pkexec for exactly this (jarvisoslinux/dmcp elevation design). |

pkexec contract (freedesktop polkit docs, verified 2026-09-27):

- Exit 0 → pacman's exit code is returned (success path).
- Exit **126** → the user **dismissed** the auth dialog → maps to
  `AuthException(kind: dismissed)` — quiet note, remediation `none`
  (operation-state-machine.md §7: "Never nag the user for saying no").
- Exit **127** → not authorized / auth error / pkexec-level failure →
  `PermissionException` with the stderr text.
- pkexec uses the session's registered auth agent; with **no agent**
  it registers its own *textual* agent — which needs a TTY the store
  does not have. Consequence, stated plainly: **on a session without a
  polkit agent (e.g. bare WM, headless), the prompt cannot be answered
  and the operation fails typed** (`PermissionException`,
  `neededAccess: 'polkit authentication agent'`). The store must not
  invent its own password dialog (contract: backends show no dialogs).

What happens without auth (the honest failure ladder):

1. `pkexec` binary missing (no polkit installed — Arch does not ship
   polkit by default) → `Process.start` throws → transport raises
   `PacmanCommandException(args, 127, 'pkexec not found')` →
   `PermissionException(debugDetail: 'polkit/pkexec not installed…',
   neededAccess: 'polkit (pkexec) for privileged pacman operations',
   remediation: fixBackend)`.
2. User dismisses → 126 → `AuthException(dismissed)`.
3. Auth fails/denied → 127 → `PermissionException`.
4. pkexec succeeds but pacman still complains
   `error: you cannot perform this operation unless you are root.`
   (verified exact stderr text) → defense-in-depth mapping to
   `PermissionException` (should not happen; if it does, elevation
   silently failed).

The `authenticating` phase is real: the handle emits `Authenticating`
between spawn and the first pacman stdout line (the polkit prompt is
in flight exactly then). First pacman output → `preparing` (the DAG
allows `authenticating → preparing`).

---

## 5. AUR — explicitly OUT OF SCOPE

`pacman` does not speak AUR at all (`-Ss`/`-Si` search sync dbs only),
so AUR support would mean shelling out to a **user-specific AUR
helper** (`yay`, `paru`, …):

- No stable interface: helpers differ in flags, output, and config;
  none is installed by default; the user may have none, one, or three.
- Privilege model conflict: AUR builds **must not run as root**
  (`makepkg` refuses); the §4 pkexec model is the wrong vehicle for
  builds.
- Trust model conflict: AUR = user-reviewed PKGBUILDs. A store
  one-click-installing AUR packages without the review step would be
  dishonest about what it is doing.

DECIDED: the backend never shells out to an AUR helper. `pacman -Qm`
(foreign packages) is not enumerated specially; an installed AUR
package still gets honest *details* via the `-Qi` fallback (§2.4) and
appears in `listInstalled()` (it is installed, after all), but
install/upgrade of AUR packages is out of scope. If a future slice
wants AUR, it is a separate backend with its own trust UX — not an
extension of this one.

---

## 6. Search semantics

- `search(query)` = `pacman -Ss -- <RegExp.escape(query)>` (§2.2),
  parsed into `AppInfo` cards (one per header block).
- Matches **name and description** (pacman behavior); no relevance
  ranking in MVP — sync-db order.
- Results carry `installed: true` when the `[installed]` flag is
  present; `installedVersion` then comes from a `pacman -Q <name>`
  lookup only if the UI needs it (MVP: leave null on search cards —
  the Manage page re-derives from `listInstalled()`; documented, not
  hidden).
- Requires a synced db; a stale db yields stale results (§7).
- Cancellation: the contract requires search streams to stop backend
  work within 500ms — killing the `pacman -Ss` child satisfies it
  (same as flatpak).

---

## 7. checkUpdates and the `-Sy` staleness caveat

Two paths, in preference order (§2.5–2.6):

1. **`checkupdates`** (pacman-contrib present): exit 0 → parse lines;
   exit 2 → `[]`; exit 1 → typed error. It syncs its own fakeroot db —
   fresh results, no root, no db lock.
2. **`pacman -Qu`** (fallback): exit-code quirk handled by
   stdout/stderr inspection (§2.5); same line shape; `[...]`-lines
   dropped.

**The staleness caveat, stated honestly:** raw `-Qu` reads the real
sync db, which is only as fresh as the last `-Sy`. The backend
**must not run `pacman -Sy` itself** to fix this: a sync without a
full upgrade is a *partial upgrade*, which the Arch wiki documents as
unsupported and a known breakage vector. So the fallback path may
report stale (or empty) update lists, and the docs say so. The
`checkupdates` path does not have this problem (own fakeroot sync)
which is exactly why it is preferred. Per-backend timeout
(parallel-check-updates.md, `updates.backend_timeout_ms` 30s) bounds
both paths; the fakeroot sync inside `checkupdates` is the slow one
and the 30s budget covers it on healthy systems.

---

## 8. Kill semantics — cancel is SIGTERM→SIGKILL, and it is not atomic

- `cancel()` → handle emits `cancelling` within 2s (prompt ack), then
  `transport.terminate()`: `SIGTERM`, 2s grace, `SIGKILL` — the same
  shape as flatpak's `_CliProcess.terminate`.
- **Honest non-atomicity:** unlike PackageKit's daemon-side
  transactions, killing `pacman` mid-commit is **not transactional**.
  SIGTERM during *download* is safe (partial `.part` files are
  re-fetched next run); SIGKILL during *apply* can leave the system
  half-configured. The next `pacman -Su` completes the transaction —
  the docs say this instead of pretending `cancelled` means
  "untouched".
- Cancel-then-fail races resolve to `Cancelled`, never `Failed`
  (operation-state-machine.md §3): if the child died from our signal
  (exit −SIGTERM/−SIGKILL), the handle reports `cancelled` even if
  pacman also printed errors. If the child exited 0 after a cancel
  request (it committed before the signal landed), the handle reports
  `done(cancelRequested: true)` — the DAG-legal `cancelling → done`.

---

## 9. Design decisions forced by this research

- **D1 — Transport = `pacman` CLI subprocess.** `CliPacmanTransport`
  mirrors `CliFlatpakTransport` (run/spawn/terminate). No libalpm FFI:
  no Dart binding exists (verified), and a child process is the only
  vehicle that supports the 2s cancel-ack rule (§1).
- **D2 — `PacmanPackageId` = `name;version;arch;repo` (4 tokens),
  version opaque.** `;` is safe: pacman names/versions/arches/repos
  never contain it. Card key = **name alone** (§3 — alpm's local db is
  name-keyed; Arch multilib renames instead of multi-arching).
  Mutating calls use `repo/name` when repo is known, else the bare
  name — mirroring rpm's mutate-time re-resolution (origin shifts;
  here: repo is absent from the `-Q` path).
- **D3 — Bulk `listInstalled()` = one `pacman -Q` invocation.** N+1 is
  dead (bulk-installed.md): no per-package `-Qi` in the list path —
  that call belongs to `getDetails()` only. Unparseable lines are
  skipped, never fatal; total failure → typed error (host contract:
  partial results, never throw).
- **D4 — Privilege = `pkexec` per mutating operation** (§4). Exit 126
  → `AuthException(dismissed)`; 127 → `PermissionException`; missing
  pkexec → `PermissionException` with polkit-install remediation.
  `authenticating` is a real phase between spawn and first pacman
  output.
- **D5 — `checkUpdates()` = `checkupdates` preferred, `pacman -Qu`
  fallback** (§7). Exit-code quirks handled by stdout/stderr
  inspection, never by code alone. The backend never runs `-Sy`
  (partial-upgrade doctrine).
- **D6 — AUR out of scope** (§5). No AUR-helper subprocesses, ever, in
  this slice. `-Qi` fallback gives honest details for foreign
  packages; install/upgrade stays sync-db-only.
- **D7 — Progress = parsed line events + 60s heartbeat, never
  fabricated** (§2.7–2.8). `Total Download Size:` → bytesTotal;
  `(N/M)` → applying fraction; ` downloading...`/summary lines →
  liveness. `bytesDone` has no honest per-byte source through a pipe —
  indeterminate download is the documented MVP posture; `-Sp`
  planning is the recorded future lever.
- **D8 — Cancel = SIGTERM→2s→SIGKILL; non-atomicity documented**
  (§8). The docs say what `cancelled` does and does not promise for a
  killed pacman.
- **D9 — Capabilities: `{search, details, install, remove, update,
  permissions}`.** `permissions` = the unsandboxed disclosure
  (pacman packages run unsandboxed — ADR-009, same as deb/rpm).
  `ratings` excluded (ADR-005).
- **D10 — `AppSource.pacman` + labeling honesty.** Every pacman result
  carries it, never `deb` (platform-detection.md's Fedora lesson:
  mislabeled rows are worse than no rows).
- **D11 — `backend.pacman.enabled` defaults OFF; seeded ON for
  arch-like.** Unlike rpm (seeding deferred — shared PackageKit probe
  with deb), the pacman probe (`pacman --version`) only passes where
  pacman exists, so seeding on for `isArchLike` is safe and makes the
  backend work out of the box where it belongs. Explicitly decided
  here, not deferred. `catalog.backend_order` untouched in this slice.
- **D12 — Search escapes the query as a literal regex** (`-Ss` args
  are regexes; unescaped user input would be a correctness bug and a
  ReDoS-adjacent footgun).

## 10. Open questions for the HLD/LLD slice

1. `-Rs` (cascade remove) vs `-R` (package only) for `remove()` — HLD
   locks `-R`; `-Rs` needs its own UX decision.
2. The `[installed: <ver>]` long form in `-Ss` flags — accept-and-ignore
   vs parse; dogfood decides (HLD §7 records it as to-verify).
3. `-Sp` resolver planning as a pre-install sizing step — LLD records
   the seam but does not implement it.
4. Custom polkit action (`org.libreappstore.pacman`) replacing raw
   `pkexec pacman` — v2 packaging work, not this slice.

## 11. Verification log

- 2026-09-27: pub.dev search (`alpm`, `pacman`) + GitHub `alpm` topic
  page — bindings exist for Rust/Go/Vala/Python/C++, **none for Dart**.
- 2026-09-27: Arch wiki "Pacman" ("Querying package databases"),
  pacman Rosetta — `-Q`/`-Ss`/`-Si`/`-Qu` roles; `-Ss` searches name
  + description; args are regexes.
- 2026-09-27: pacman-contrib mailing list — checkupdates.sh.in
  (fakeroot `-Sy` into temp db, `pacman -Qu --dbpath` +
  `grep -v '\[.*\]'`), exit codes 0/1/2 (CHANGES.md: "Exit with 2 if
  there are no updates available"); `pacman -Qu` exits 1 when no
  updates ("compatibility with pacman -Qu").
- 2026-09-27: pacman-dev list — `humanize_size` `%.2f` + B/KiB/MiB/GiB
  units for `Download Size`/`Installed Size`.
- 2026-09-27: freedesktop polkit docs (pkexec.1) — exit 126
  dismissed / 127 not-authorized-or-error; session agent with textual
  fallback.
- 2026-09-27: Arch forums — progress bars off when piped ("common
  practice… when the output is to a pipe"); pacman(8) `--noprogressbar`
  "useful for scripts that call pacman and capture the output".
- 2026-09-27: archinstall issue log + msys2 `--noconfirm` capture —
  `--noconfirm` prints `Total Download Size:`/`Total Installed Size:`
  summary then walks past `Proceed with installation? [Y/n]`; non-TTY
  per-file `<file> downloading...` lines.
- 2026-09-27: tux_store DOCS/PACMAN_MANAGER.md (real pacman-CLI
  consumer) — `-Si`-then-`-Qi` cascade, `"\n\n"` block split,
  two-space continuation lines, `-Sp --print-format "%n|%s"` resolver
  plan, case-insensitive size parsing.
- 2026-09-27: emrac CHANGELOG (live-verified by its author) —
  `-S <pkg> --print` root-free, `-Syu --print` needs root for `-y`;
  `-Su --print` works off the cached db.
- 2026-09-27: jarvisoslinux/dmcp#45 — pkexec as the standard
  per-call elevation vehicle for system tools.
- 2026-09-27: toolbox README / cmpadden blog — exact stderr text
  `error: you cannot perform this operation unless you are root.`
- NOT verified (no Arch box in sandbox): any live `pacman` output —
  every fixture in §2 is reconstructed and marked as such; the
  `[installed: <ver>]` long form; `(N/M)` bar presence when piped;
  pkexec prompt UX; `checkupdates` binary presence on stock Arch
  (pacman-contrib is *not* a default install). First Arch dogfood must
  re-verify §2 line by line.
