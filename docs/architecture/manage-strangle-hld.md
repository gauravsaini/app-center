# Manage-strangle HLD

Parent: [hld.md](hld.md). Slice of the strangler fig: moves the Manage
page (installed apps) onto the unified store stack.

## 1. Goal

The Manage page lists installed apps. Today it reaches directly into
`snapd` / PackageKit services. This slice gives the page a backend-agnostic
source: `StoreHost.installed()`, which fans out over every registered
backend and returns `UnifiedApp` cards. The UI renders cards; it never
learns what a snap or a deb is.

The documented gap this closes: `host-wiring.md` said
"`installed()` returns `[]`" pending a `StoreBackend.listInstalled()`
contract addition. That addition is this slice.

## 2. Layering

```
Manage page (UI) → StoreHost → StoreBackend(s)
                       ↑
              composition root (store_host_wiring.dart)
                       ↓
        backend_snap / backend_deb / backend_flatpak
```

- **UI → `store_host` / `store_contracts` only.** No `backend_*` imports
  — `scripts/dep_trace.py` enforces this exactly as for the other pages.
- **Backends are registered once** in
  `packages/app_center/lib/store/store_host_wiring.dart` (composition
  root). The Manage page gets the host via `storeHostProvider` and calls
  `host.installed()`. It never enumerates backends itself.
- The page is gated by the flag `pages.manage.unified` (default `false`
  in this slice): flag off → legacy Manage page path; flag on →
  `StoreHost.installed()`. One page behind one flag, so a broken
  installed-list path can be killed without touching Explore/Search.

## 3. Contract change (SemVer minor)

`store_contracts` `0.1.0` → `0.2.0`. Additive only:

- New method `StoreBackend.listInstalled()` with a **default
  implementation returning `[]`** (LLD §10: "new optional method with a
  default" = minor). Existing implementers (`FakeStoreBackend` in
  `test/`, `StubSnapBackend` in `store_host/test/`, real backends)
  compile unchanged. Default `[]` means "not supported" — backends that
  don't implement it simply contribute nothing, exactly as if the
  method never existed.
- Host contract `UnifiedCatalog.installed()` is unchanged — it was
  already declared; this slice finally wires it.

No major bump: backends still declare `contractVersion 0` and the host
accepts them. A breaking change here would have stopped this slice.

## 4. Partial-failure degradation policy

Same as `search()` / `checkUpdates()`:

- Fan out per backend; **one backend failing never fails the others**.
  A throwing `listInstalled()` degrades to partial results — the Manage
  page shows what it could enumerate plus its normal "partial results"
  posture (per host-wiring.md: a quiet "2 of 3 sources" note beats a
  mysterious missing app).
- `StoreHost.installed()` itself never throws. A backend throwing raw
  (non-`StoreException`) errors fails the exam; the host still catches
  it, because the exam can't run against production transports.

## 5. Identity discipline

v1 grouping: one `AppInfo` → one `UnifiedApp`, same as `search()`. No
cross-backend merging (thesis: duplicate cards beat unsafe merges;
real merging arrives with the community metadata index). The host maps
each returned app with the identity rule:

- `groupId = '${backend.id}:${app.identity.nativeId}'`
- `app.identity.backendId` MUST equal the backend's id (exam-enforced).

## 6. Explicitly out of scope

- **No UI rewrite of the Manage page.** This slice adds the host path
  and the flag; flipping `pages.manage.unified` to `true` for real users
  and migrating the legacy Manage UI is a later slice with its own
  exam-relevant coverage.
- **No cross-backend dedupe.** Same-app-as-snap-and-flatpak renders as
  two cards until the metadata-index merge lands.
- **No caching/staggering of `installed()`.** It is a direct fan-out,
  like `checkUpdates()` today. Startup-path scheduling (cache + TTL +
  background refresh) is the app's concern when it wires the page —
  and per HLD §5 it must stay off the UI critical path.
- **No `BackendCapability` for installed listing.** The default `[]`
  makes support implicit; capability advertising would turn an additive
  default into a coordination requirement. If a backend must *declare*
  support later, that's a new minor with its own exam check.
- **No real-backend `listInstalled()` implementations.** snap/deb/
  flatpak implementations arrive in their own slices (each passes the
  exam first).
