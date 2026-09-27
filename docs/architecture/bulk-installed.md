# Bulk installed-app listing (perf slice)

## Problem

`StoreHost.installed()` → per-backend `listInstalled()` was N+1:

- snap: `installedNames()` (1× `GET /v2/snaps`, data discarded) + per-name
  `getDetails()` (`GET /v2/snaps/<name>`) → **N+1 HTTP calls**.
- deb: `installedNames()` (1× PackageKit `GetPackages(installed)`) +
  per-name `getDetails()` = `SearchNames` tx + `GetDetails` tx → **1+2N
  transactions**.

## Mechanism (backend-internal, no contract change)

- **snap**: new `SnapdTransport.installedSnaps()` → `List<SnapSummaryData>`.
  The real transport already calls `_client.getSnaps()` (bulk `/v2/snaps`)
  inside `installedNames()` and throws the data away; the new method keeps
  it and maps via the existing `_toData`. `listInstalled()` uses it.
- **deb**: new `PackageKitTransport.installedPackages()` →
  `List<DebPackageData>`. One `GetPackages(installed)` transaction for
  name/version/summary, plus one `GetDetails(allIds)` transaction for
  descriptions (`_detailsEvents` already takes a list). Dedupe by name
  (multi-arch events share a name).
- Both are additive methods on backend-internal transport interfaces
  (not the `StoreBackend` contract). Stubs in `testing.dart` updated.

## Fallback (degrade, never throw)

If the bulk call throws a transport exception, `listInstalled()` falls
back to the previous N+1 path (kept verbatim as `_listInstalledLegacy`),
which skips per-item not-found and maps other errors as before. The host
contract — partial results, never throw — is unchanged.

## Measurements

Tests script the stub transports with call counters (N=5 apps):

- snap: before 6 transport calls (1 names + 5 details) → after **1**.
- deb: before 11 transactions (1 names + 5×2 detail) → after **2**.
- Fallback test: bulk throws → legacy path still returns the apps.

## Trade-offs / honest notes

- snap: bulk is the *same* snapshot the N+1 path re-fetched, so mapping
  parity is exact; the mid-enumeration "removed snap" skip disappears
  (single snapshot — strictly better).
- deb: bulk descriptions come from one `GetDetails` batch; a batch-wide
  failure falls back to per-package N+1 rather than failing the list.
- No live-daemon verification (sandbox has neither snapd nor
  PackageKit); stubbed-transport tests only, same as all backend tests.
