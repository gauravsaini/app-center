# deb-packageid-fix — design note

## 1. What's actually broken

`RealPackageKitTransport` (packages/backend_deb) consumes
`package:packagekit` 0.2.7's `PackageKitTransaction.events` stream.
That client parses **every** package-bearing signal through
`PackageKitPackageId.fromString`, which requires **exactly 4**
`;`-separated tokens and throws `FormatException` otherwise
(pub-cache `packagekit_client.dart:409-417`). The throw sites are
*inside* the signal-stream `.map()` (`:922`, `:951`, `:970`, `:996`,
`:1014`, `:1020`, `:1023`, `:1027`), so the event never materializes
— the listener sees an unhandled stream error and the whole
enumeration dies.

The daemon side emits **5-token** IDs. Independently verified against
PackageKit @ main (not just the rpm research doc):

- `lib/pk-package-id.c`: `pk_package_id_build(name, version, arch,
  origin, data)` → `name;version;arch;origin;data`; `pk_package_id_split`
  rejects anything but 5 sections.
- `backends/apt/apt-cache-file.cpp:483` (`AptCacheFile::buildPackageId`):
  `pk_package_id_build(name, verStr, arch, origin, data)` — apt emits
  e.g. `firefox;135.0-1;amd64;jammy-updates;manual`.

So **every** package-bearing deb transaction (`searchNames`,
`getPackages`, `getUpdates`, `getDetails`, `ItemProgress`) fails
against a real daemon. The backend never hit this because it was never
live-verified ("stubbed transports only" — appimage-backend-hld.md §7).

## 2. Fix

Rewrite `RealPackageKitTransport` over raw `package:dbus` (the rpm
D1 precedent — backend_rpm does not depend on `package:packagekit`
at all):

- Decode `Package` (`uss`), `Details` (`a{sv}`), `ItemProgress`
  (`suu`), `ErrorCode` (`us`), `Finished` (`uu`), `Destroy` signals
  ourselves (shapes read from `packagekit` 0.2.7's own decode code).
- New `DebPackageId` value type: parses `name;version;arch;origin;data`
  at the transport seam; throws `FormatException` unless 5 tokens and
  non-empty name. **Version stays opaque** (never parsed/rebuilt —
  epoch-0-style loss applies to any parse/rebuild scheme).
- Method calls take **verbatim** ID strings (`InstallPackages`,
  `RemovePackages`, `UpdatePackages`, `GetDetails`).
- Corrupt IDs are **skipped, never fatal**, in enumeration paths
  (rpm LLD §3 policy); `_resolvePackageId` skips unparsable events
  (they can't name-match anyway).

The `PackageKitTransport` abstract interface (`transport.dart`) is
already pure Dart — **no contract change**, no backend/handle/UI
changes. `packagekit: ^0.2.7` is dropped from the pubspec, replaced
by `dbus: ^0.7.6` (same as backend_rpm).

## 3. Behavior-preservation checklist (mapping parity)

| Old (vendored) | New (raw) | Parity |
|---|---|---|
| `PackageKitFilter.installed` mask | `1 << 2` (enum order verified) | same query |
| `searchNames` filter `{}` | mask `0` | same |
| `PackageKitInfo.installed` | info uint `== 1` | same |
| `_mapStatus` enum switch | numeric ordinals 8,20–25→download; 9→install; 6→remove; 10→update; 14→verifying; else other | identical |
| exit success/cancelled/cancelledPriority/killed | `1`→success; `3,6,9`→cancelled; else failed | identical |
| `event.code.name` (e.g. `packageNotFound`) | `_errorNames[code]` — same 0.2.7 enum order, out-of-range→`'unknown'` | identical names (backend `_mapError` keys off these) |
| `RemovePackages(flags, ids, false, false)` | `(u64 0, as [verbatim], b false, b false)` | identical |
| Timeouts: 2s connect/probe, 30s query/details | same | identical |
| Multi-arch: one card per **name** (deb), prefer installed | same grouping in `mergeInstalledPackages` | identical cards |

## 4. Regression scope

- `test/bulk_installed_test.dart`: fixtures move from
  `PackageKitPackageEvent`/`PackageKitDetailsEvent` to the new raw
  types (`DebRawPackage`/`DebRawDetails`); the packagekit import is
  dropped. The 16 scenarios stay green — same cards asserted.
- New tests: `DebPackageId.parse` (5-token ok, 4-token throws,
  empty-name throws, verbatim round-trip), mapping parity
  (5-token fixtures → same `DebPackageData` the old tests asserted),
  corrupt-ID skip policy, `_errorName` boundary.
- `exam_test.dart`, `heartbeat_test.dart`: stub-based, untouched.
- `melos test`, `analyze --fatal-infos`, `format:exclude`,
  `dep_trace.py` zero new violations.

## 5. Honest gaps (unchanged by this slice)

- No live-daemon verification (no PackageKit/apt daemon in sandbox) —
  wire shapes are cited from `packagekit` 0.2.7 source + the rpm
  transport's verified claims.
- `GetDetails` on a verbatim ID the daemon no longer knows is a
  daemon-side no-op; the batch still returns other details.
