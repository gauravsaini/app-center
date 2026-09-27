# RPM backend — transport research

**Status:** research leaf, read-only. No implementation code written.
**Branch:** `feat/backend-rpm` · **Package:** `packages/backend_rpm` (to be created)
**Parent docs:** [hld.md](hld.md), [lld.md](lld.md), [host-wiring.md](host-wiring.md)
**Pattern to follow:** `packages/backend_{snap,deb,flatpak}` — all outside-world
contact goes through an injectable `Transport`; tests script a stub
(see `packages/backend_deb/lib/src/transport.dart`).

This note answers, with verified evidence, what the RPM transport can
and cannot rely on. Every behavioral claim below is either read from
the PackageKit source (cloned 2026-09-27, commit `4129445`) or cited to
a live source. Nothing here was measured on a Fedora box — the sandbox
has none — so every claim names its source. The design decisions it
forces are collected in §8.

---

## 1. PackageKit on Fedora: the dnf5 backend

PackageKit 1.4.0 was released 2026-09-09
([Wikipedia](http://en.wikipedia.org/wiki/PackageKit)) and has been
Fedora's package-management D-Bus layer since Fedora 9 — GNOME Software
uses it as its RPM source on Fedora. The backend that serves it today is
**`backends/dnf5`** (C++, libdnf5; author Neal Gompa, 2025), which
replaced the old Python `dnf`/`yum` backends. Its declared roles
(`pk-backend-dnf5.cpp`, `pk_backend_get_roles`):

> `DEPENDS_ON, DOWNLOAD_PACKAGES, GET_DETAILS, GET_DETAILS_LOCAL,`
> `GET_FILES, GET_FILES_LOCAL, GET_PACKAGES, GET_REPO_LIST,`
> `INSTALL_FILES, INSTALL_PACKAGES, REMOVE_PACKAGES, UPDATE_PACKAGES,`
> `REPAIR_SYSTEM, UPGRADE_SYSTEM, REPO_ENABLE, REPO_REMOVE,`
> `REPO_SET_DATA, REQUIRED_BY, RESOLVE, REFRESH_CACHE, GET_UPDATES,`
> `GET_UPDATE_DETAIL, WHAT_PROVIDES, SEARCH_NAME, SEARCH_DETAILS,`
> `SEARCH_FILE, CANCEL`

Every role the store needs — `GetPackages`, `GetDetails`,
`InstallPackages`, `RemovePackages`, `UpdatePackages`, `GetUpdates`,
`SearchName`, `SearchDetails`, `RefreshCache` — is implemented. The
backend advertises mime type `application/x-rpm` and supports
parallelization.

**Q1 verdict:** yes — `GetPackages`/`GetDetails`/`InstallPackages`/
`RemovePackages`/`UpdatePackages` all work against the dnf backend.
The deb **bulk pattern transfers 1:1**: one `GetPackages(installed)`
transaction plus one batched `GetDetails` transaction is the same D-Bus
API on both backends; nothing about it is apt-specific.

### 1.1 Filters: what differs from apt

`dnf5_apply_filters` (`dnf5-backend-utils.cpp`) implements:

| Filter | dnf5 meaning (source) |
|---|---|
| `installed` / `notInstalled` | `query.filter_installed()` / `filter_available()` |
| `arch` | `filter_arch({native_arch, "noarch"})` — drops compat arches (i686 on x86_64) |
| `newest` | `filter_latest_evr()` |
| `gui` / `notGui` | package provides `application(...)` — i.e. ships a `.desktop` file |
| `development`, `source`, `supported`, `downloaded` (+ negations) | repo-property based (devel/source/supported repos, locally cached) |

The **`gui` filter is the one the deb backend does not have** and the
most useful for a store: it selects exactly the packages that ship a
desktop entry. It is *not* in the MVP query set (§8 D3) — kept as a
documented future lever.

### 1.2 Package-ID format: 5 tokens, EVR opaque

`dnf5_build_package_id` calls
`pk_package_id_build(name, evr, arch, origin, data)` — the standard
5-component form `name;evr;arch;origin;data`
(`lib/pk-package-id.c`). Example:

```
firefox;135.0-1.fc42;x86_64;updates;installed
```

- `evr` is libdnf5's `epoch:version-release`, with **epoch 0 omitted**
  (dnf5 `repoquery --queryformat` docs:
  "`evr` — Display epoch:version-release of the package. Epoch 0 is
  omitted",
  [repoquery.8.rst](https://github.com/rpm-software-management/dnf5/blob/HEAD/doc/commands/repoquery.8.rst)).
- `origin` is the repo id the package comes from (`fedora`,
  `updates`, …) or the from-repo for installed packages; `data` is
  `"installed"` for installed packages, empty otherwise.

**The EVR must be treated as opaque.** Epoch-0 omission means the
string cannot be round-tripped through parse/rebuild code — the
backend must carry package-id strings verbatim and never
parse-and-reconstruct them. `dnf5_resolve_package_ids` resolves a full
ID via `filter_name` + `filter_evr` + `filter_arch` (+ repo id), so
verbatim IDs resolve.

### 1.3 ⚠️ Vendored Dart client cannot parse dnf5 package IDs

`package:packagekit` 0.2.7 (the client the deb backend's
`RealPackageKitTransport` uses) parses IDs with
`PackageKitPackageId.fromString`, which **requires exactly 4 `;`-separated
tokens and throws `FormatException` otherwise**
(`packagekit_client.dart`). Both the apt and dnf5 backends emit
**5-token** IDs. The throw happens inside the signal-stream `.map()`,
so every package-bearing transaction against a real daemon would fail
with an unhandled stream error. The deb transport never hit this
because it was never live-verified ("stubbed transports only" —
`appimage-backend-hld.md` §7).

**Forced:** D1 (§8) — the rpm transport must parse 5-token IDs itself
at the transport seam; it cannot reuse the vendored client's strict
parser. (This is also a latent bug in the deb backend — flagged as a
follow-up, out of this slice.)

---

## 2. Search: PackageKit vs `dnf` CLI

`dnf5_query_thread` (`dnf5-backend-thread.cpp`):

- `SEARCH_NAME`: `query.filter_name(terms, ICONTAINS)` — substring
  match on the package name.
- `SEARCH_DETAILS`: `filter_description(terms, ICONTAINS)` **union**
  `filter_summary(terms, ICONTAINS)` — searches description and
  summary, not the name.

Both then apply the requested filters and emit via
`dnf5_sort_and_emit`, which **dedupes by NEVRA** (`name;evr;arch`) —
multi-arch results arrive as separate entries (§5).

`Package` events carry only `(info, package_id, summary)`. Full
metadata comes from `GetDetails`, which emits the `Details` dict
(`a{sv}`): `package-id`, `summary`, `license` (`"unknown"` fallback),
`group` (**always `PK_GROUP_ENUM_UNKNOWN`** — comps integration is
explicitly undecided, per the backend README), `description`, `url`
(homepage), `size` (install size), `download-size`. The Dart client
surfaces `size` but not `download-size` (§7).

**Honest catalog source: PackageKit.** Typed D-Bus events, no stdout
parsing, and the same source GNOME Software uses on Fedora. `dnf list`
/ `dnf search` CLI parsing is rejected: tabular output is locale- and
version-sensitive, and shelling out to `dnf` would need root for some
paths while PackageKit's daemon is already root-activated.

---

## 3. checkUpdates: `GetUpdates` semantics

`GET_UPDATES` runs a real libdnf5 solver pass
(`dnf5-backend-thread.cpp`): `goal.add_rpm_upgrade()` (or
distro-sync when configured) → `goal.resolve()` → transaction
packages with `UPGRADE`/`INSTALL` actions. Advisory data is joined per
package for severity (`PK_INFO_ENUM` security/normal/…).

Semantics, per the D-Bus API contract
([Transaction API](https://www.freedesktop.org/software/PackageKit/gtk-doc/Transaction.html)):
"return a list of packages that are installed and are upgradable…
only the newest update for each installed package." The solver
guarantees the newest-per-installed-package property — the backend
never has to dedupe.

For comparison, `dnf check-update` / `dnf5 check-upgrade` exit codes
([check-upgrade.8.rst](https://github.com/rpm-software-management/dnf5/blob/HEAD/doc/commands/check-upgrade.8.rst),
[dnf5.8.rst](https://github.com/rpm-software-management/dnf5/blob/HEAD/doc/dnf5.8.rst)):
`100` = updates available, `0` = none, `1` = error. `GetUpdates` is
strictly richer (per-package versions, severity, CVE/Bugzilla URLs via
`GetUpdateDetail`, changelog, reboot-suggested flag) and needs no
exit-code parsing. `UpdatePackages` then applies them.

**Q3 verdict:** `checkUpdates()` = one `GetUpdates` transaction.
Never shell out to `dnf check-update`.

---

## 4. listInstalled: bulk via `GetPackages(FILTER_INSTALLED)`

`FILTER_INSTALLED` maps to `query.filter_installed()`
(`dnf5_apply_filters`) — works on the dnf5 backend, same as apt. The
deb bulk shape transfers exactly: one `GetPackages({installed})`
transaction → one batched `GetDetails(ids)` transaction → merge.

Two rpm-specific notes:

- **No arch filter on the installed enumeration.** Installed i686
  packages on an x86_64 system must still list; `FILTER_ARCH` would
  hide them. (§5.)
- `GetDetails` on the dnf5 backend takes the full 5-token IDs; the
  batch path in the deb transport (`_detailsEvents`) is reusable
  modulo D1's ID parsing.

**Q4 verdict:** confirmed — `FILTER_INSTALLED` works; the deb bulk
pattern (2 transactions, degrade to per-package on batch failure)
transfers.

---

## 5. Identity: (name, arch), EVR opaque, multi-arch are separate cards

- `dnf5_sort_and_emit` dedupes by `name;evr;arch` — a package
  installed as both `x86_64` and `i686` emits **two entries**. This
  differs from the deb backend's one-card-per-name merge
  (`mergeInstalledPackages` groups by name).
- The store card key for rpm is therefore **(name, arch)**, and the
  `nativeId` is the **full package-id verbatim** (`name;evr;arch;origin`
  — data field dropped or kept verbatim; never reconstructed).
- Epoch handling: epoch 0 is omitted from the EVR string (§1.2), so
  `1.2-3.fc42` and `1:1.2-3.fc42` are different packages that must
  never be compared by string surgery — verbatim carry is the only
  safe rule.
- For mutating calls, re-resolve by (name, arch): `dnf5_resolve_package_ids`
  also accepts a bare name (resolves to latest available in supported
  arches). Origin/repo fields can shift between query and transaction
  (e.g. `fedora` → `updates`), so the transport resolves fresh at
  mutate time rather than trusting a cached origin — mirroring the deb
  backend's `_resolvePackageId`.

**Q5 verdict:** identity = verbatim package-id; cards keyed (name,
arch); multi-arch = separate cards (the honest rpm answer, unlike
deb's name-merge).

---

## 6. Privilege: polkit, per-role — verified from daemon + policy source

`pk-transaction.c` maps roles to polkit actions; the shipped policy
(`data/policy/org.freedesktop.packagekit.policy.in`) sets:

| Role | polkit action | active local session |
|---|---|---|
| `InstallPackages` | `org.freedesktop.packagekit.package-install` | `auth_admin_keep` — password prompt |
| `RemovePackages` | `org.freedesktop.packagekit.package-remove` | `auth_admin_keep` — password prompt |
| `UpdatePackages` | `org.freedesktop.packagekit.system-update` | **`yes` — no prompt** (comment: "Normal users do not require admin authentication to update the system… Changing this to anything other than 'yes' will break unattended updates.") |

The PackageKit daemon is D-Bus-activated and runs as root — the store
never needs sudo and **must not shell out to `dnf`** (which would need
root for mutate paths). The `authenticating` operation state is real
for install/remove on Fedora; updates typically skip it. The existing
operation state machine already models both paths; the rpm handle
reuses the deb handle's phase mapping.

**Q6 verdict:** polkit prompts for install/remove, none for update
on stock Fedora. The operation engine needs no new privilege
machinery — same as the deb backend.

---

## 7. What's NOT available (honest gaps)

- **Per-app icons: not on the D-Bus surface.** Zero icon code exists
  in the dnf5 backend; no `Details` field, no signal. GNOME Software
  gets icons from **AppStream** metadata, read separately — an
  AppStream XML consumer is a post-MVP subsystem, not part of this
  slice. MVP `iconUrl` = `''`, same as the deb backend.
- **Groups: always UNKNOWN.** `pk_backend_job_details` is called with
  `PK_GROUP_ENUM_UNKNOWN`; the backend README lists "How to access
  comps data" as undecided. No category mapping from PackageKit.
- **Download size: on the wire, not in the Dart client.** The
  `Details` dict carries both `size` (install size) and
  `download-size`; `package:packagekit` 0.2.7 only surfaces `size`.
  MVP reports install size; download size is a known wire-available
  gap pending the D1 parser work.
- **Ratings/screenshots/reviews:** nothing in PackageKit. Same as
  every other backend (ADR-005).
- **RefreshCache needs auth** (`system-sources-refresh`), so the MVP
  never forces a refresh per operation — it relies on the daemon's
  own metadata freshness (PackageKit caches under
  `/var/cache/PackageKit/$releasever/metadata/`). A stale-metadata
  `GetUpdates` is possible; documented, not solved in MVP.

---

## 8. Design decisions forced by this research

- **D1 — Transport = PackageKit D-Bus with a 5-token-tolerant ID
  parser.** `RpmPackageKitTransport` speaks the same D-Bus roles as the
  deb transport, but parses `name;evr;arch;origin;data` itself at the
  seam — it must NOT route IDs through `package:packagekit`'s strict
  4-token `fromString` (verified to throw on real backend output).
  EVR is opaque end-to-end: carried verbatim, never parsed or
  rebuilt. (Also flags the same latent bug in the deb backend —
  separate follow-up slice.)
- **D2 — Bulk installed pattern transfers, keyed (name, arch).**
  `GetPackages({installed})` + one batched `GetDetails`; dedupe by
  NEVRA (name+arch), not by name — multi-arch packages are separate
  cards. Batch failure degrades to the per-package legacy path, same
  as deb.
- **D3 — Search passes `FILTER_ARCH`; installed listing does not.**
  `SearchName` with the arch filter (native + noarch) keeps catalog
  cards store-sane; the installed enumeration omits it so installed
  i686 packages still list. `FILTER_GUI` (application() provides) is a
  documented future lever, not MVP.
- **D4 — Identity = verbatim package-id; mutate-time re-resolution.**
  `nativeId` is the full package-id string, opaque. Install/remove/
  update re-resolve by (name, arch) at mutate time (origin shifts
  between query and transaction), mirroring deb's `_resolvePackageId`.
- **D5 — `checkUpdates()` = `GetUpdates`, solver-based.** Newest
  update per installed package, advisory severity included. No
  `RefreshCache` per op (auth-gated); no `dnf check-update` subprocess.
- **D6 — Capabilities: `{search, details, install, remove, update,
  permissions}`.** `permissions` carries the deb-style unsandboxed
  disclosure (RPMs are unsandboxed — same honesty as debs, ADR-009).
  `ratings` excluded (ADR-005).
- **D7 — `AppSource.rpm` + labeling honesty.** `store_contracts`
  gains `AppSource.rpm`; every rpm result carries it, **never `deb`**.
  (Fedora-like systems have deb disabled by platform seeding —
  mislabeled rpm rows would corrupt the Manage page.)
- **D8 — Flag `backend.rpm.enabled`, default OFF.** Platform seeding
  to enable it on fedora-like systems is a separate future decision —
  documented here, not implemented in this slice (the backend doesn't
  exist yet).
- **D9 — Privilege needs no new machinery.** install/remove hit the
  `authenticating` state via polkit; updates usually skip it. The deb
  handle's phase mapping + 60s heartbeat + 2s cancel ack transfer
  unchanged.
- **D10 — No `dnf` CLI subprocesses in MVP.** All reads and mutates
  go over D-Bus to the root-activated daemon. `dnf` is a research
  reference only.

## 9. Open questions for the HLD/LLD slice

1. Tolerant-parser placement: transport-level parsing (locked by D1)
   vs vendoring a patched `packagekit` client — HLD to lock the
   former (no dependency change).
2. `GetUpdateDetail` (CVE/Bugzilla/changelog/reboot-suggested)
   surfacing in `AppDetails` — LLD decides the field mapping.
3. AppStream icons post-MVP: separate subsystem, not this slice.
4. Whether `catalog.backend_order` should mention rpm when the flag
   is eventually enabled (explicit operator setting — deferred with
   D8).

## 10. Verification log

- 2026-09-27: cloned `github.com/PackageKit/PackageKit` @ `4129445`;
  read `backends/dnf5/` (`pk-backend-dnf5.cpp` roles, `README.md`,
  `dnf5-backend-thread.cpp` query/update/details paths,
  `dnf5-backend-utils.cpp` filter + package-id + resolve logic),
  `src/pk-transaction.c` (role→polkit mapping),
  `data/policy/org.freedesktop.packagekit.policy.in` (per-action
  defaults), `src/pk-backend-job.c` + `lib/pk-package-id.c`
  (Details dict keys, 5-token ID construction),
  `backends/apt/apt-cache-file.cpp` (apt also emits 5-token IDs).
- 2026-09-27: `package:packagekit` 0.2.7 (pub cache) —
  `PackageKitPackageId.fromString` requires exactly 4 tokens; the
  throw site is inside the signal-stream `.map()` (unhandled).
- 2026-09-27: dnf5 docs
  ([check-upgrade.8.rst](https://github.com/rpm-software-management/dnf5/blob/HEAD/doc/commands/check-upgrade.8.rst),
  [dnf5.8.rst](https://github.com/rpm-software-management/dnf5/blob/HEAD/doc/dnf5.8.rst),
  [repoquery.8.rst](https://github.com/rpm-software-management/dnf5/blob/HEAD/doc/commands/repoquery.8.rst))
  for check-upgrade exit codes (100/0/1) and the `evr` epoch-0-omitted
  rule; freedesktop
  [Transaction API](https://www.freedesktop.org/software/PackageKit/gtk-doc/Transaction.html)
  for GetUpdates/GetDetails/SearchName contracts.
- NOT verified (no Fedora box in sandbox): any live D-Bus exchange,
  real `GetPackages` output shape, polkit prompt UX, daemon
  activation latency. The HLD/LLD exam therefore scripts a stub
  transport with 5-token IDs — the stub is the contract.
