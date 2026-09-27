# Updates-strangle HLD + LLD

Parent: [hld.md](hld.md), [manage-strangle-hld.md](manage-strangle-hld.md).
Slice of the strangler fig: moves the **updates** surface
(Manage page updates section, nav badge, update-all action) off the
legacy update models (`snapUpdatesModelProvider`,
`localDebUpdatesModelProvider`) onto the unified store stack.

The host side is already done: `StoreHost.checkUpdates()` is wired
end-to-end (contract in `packages/store_contracts`, impls in
`backend_snap`/`backend_deb`/`backend_flatpak`, host fans out with
per-backend degradation — see [host-wiring.md](host-wiring.md)).
This leaf adds the app-side half: the flag and the unified provider.
Two sibling leaves build on it: **LEAF B** (nav badge) and **LEAF C**
(Manage page updates section).

## HLD

### 1. Goal

The Manage page shows per-app updates and "update all" today by
reading `snapUpdatesModelProvider` (snapd change feed) and
`localDebUpdatesModelProvider` (PackageKit). This slice gives the page
a backend-agnostic source: `StoreHost.checkUpdates()`, which fans out
over every registered backend and returns one `UpdateInfo` per
available update. The UI renders update rows; it never learns what a
snap or a deb is.

### 2. Strangler-fig approach

```
Legacy:  ManagePage → snapUpdatesModelProvider / localDebUpdatesModelProvider
                            (per-backend services, unchanged in this slice)
Unified: ManagePage → unifiedUpdatesProvider → StoreHost.checkUpdates()
                                                  → backend_snap/backend_deb/backend_flatpak
```

- Flag `pages.updates.unified` (default `false`, ADR-010:
  owner `libreapp-center`, removal date `2027-06-30`): flag off →
  legacy update models; flag on → `unifiedUpdatesProvider`.
  Same key convention as `pages.manage.unified`
  (`pages.<page>.unified` — per-page strangler switch), documented in
  the key-conventions doc comment in `flags.dart`.
- No contract change, no version bump: `checkUpdates()` already
  exists in `store_contracts` and is already exam-covered. The flag and
  the provider are app-layer additions only.
- One updates surface behind one flag, so a broken unified-updates
  path can be killed without touching the installed-apps strangle
  (`pages.manage.unified`) or Explore/Search.
- Keep-alive semantics: the provider is **not** auto-disposed.
  An update changes what this list contains, and the list must outlive
  any single view while the engine reports the update in flight.
  Callers invalidate after an update to refresh.

### 3. Entity diagram

```
Manage page (UI)
    │ reads (flag on)
    ▼
unifiedUpdatesProvider : FutureProvider<List<UpdateInfo>>
    │ ref.watch(storeHostProvider)
    ▼
StoreHost.checkUpdates()              ← host fans out over enabledBackends(),
    │ per-backend try/catch, never throws; partial results on failure
    ├── backend_snap.checkUpdates()
    ├── backend_deb.checkUpdates()
    └── backend_flatpak.checkUpdates()
```

No `backend_*` imports in the app UI layer — this file sees only the
host and the contracts, exactly like `unified_installed_provider.dart`.
`scripts/dep_trace.py` enforces this the same way as the other pages.

Consumers of the provider:

- **Badge consumer (LEAF B):** nav badge showing update count.
- **Updates-section consumer (LEAF C):** Manage page section listing
  rows from `List<UpdateInfo>`.
- **Update-all action:** starts a host update operation per
  `UpdateInfo.identity`, then invalidates the provider.

### 4. Explicitly out of scope

- **No UI migration of the Manage page.** Flag off is the default;
  legacy update models keep running unchanged. The page flip is the
  sibling leaves' scope (LEAF B badge, LEAF C section).
- **No caching/staggering of `checkUpdates()`.** It is a direct
  fan-out, like today. Startup-path scheduling (cache + TTL +
  background refresh) is the app's concern when it wires the page —
  and per HLD §5 it must stay off the UI critical path.
- **No cross-backend dedupe of updates.** Same-app-as-snap-and-
  flatpak with both updatable renders as two rows until the
  metadata-index merge lands (same thesis as manage-strangle HLD §5:
  duplicate rows beat unsafe merges).
- **No `BackendCapability` change.** `checkUpdates()` is a standing
  contract method, not capability-gated.
- **No changes to the host fan-out.** `checkUpdates()` semantics
  (sequential fan-out, per-backend try/catch, never throws) are
  settled in host-wiring.md and untouched here.

## LLD

### 5. Entities touched

| Entity | Package | Change |
|---|---|---|
| `MapFeatureFlags` | `store_host` (`flags.dart`) | + `pages.updates.unified` default `false` |
| `unifiedUpdatesProvider` | `app_center` (`lib/manage/unified_updates_provider.dart`) | new (this leaf) |
| badge consumer | `app_center` | LEAF B — reads this provider |
| updates-section consumer | `app_center` | LEAF C — reads this provider |

### 6. Flag: `pages.updates.unified` — exact contract

```dart
'pages.updates.unified': false,
```

- Convention: `pages.<page>.unified` — per-page strangler switch:
  `true` = updates surface reads from `StoreHost`; `false` (default)
  = legacy update models (`snapUpdatesModelProvider`,
  `localDebUpdatesModelProvider`).
- Owner: `libreapp-center`. Removal date: `2027-06-30` — by then the
  updates surface must be fully unified and the flag deleted.
- Registered in `MapFeatureFlags._defaults`; documented in the
  key-conventions doc comment in `flags.dart`; unknown keys still
  never throw.
- Note the flag gates the *page*, not the host method.
  `StoreHost.checkUpdates()` is not flag-gated — same as
  `installed()`: flags gate backends, not catalog reads.

### 7. Provider: `unifiedUpdatesProvider` — exact contract

```dart
final unifiedUpdatesProvider = FutureProvider<List<UpdateInfo>>(
  (ref) => ref.watch(storeHostProvider).checkUpdates(),
  name: 'unifiedUpdatesProvider',
);
```

- Location: `packages/app_center/lib/manage/unified_updates_provider.dart`,
  mirroring `unified_installed_provider.dart` (same doc-comment style,
  same imports: `package:app_center/store/store_host_wiring.dart` for
  `storeHostProvider`, `package:store_host/store_host.dart` for the
  types, `flutter_riverpod`). No `backend_*` imports by design.
- Keep-alive: not auto-disposed; callers invalidate after an update
  (per update row or after update-all) to refresh. The host never
  throws for backend failures (partial results), so the provider only
  errors if something above the host breaks (e.g. host construction
  or an unregistered backend kill-switch misuse).
- Error posture for consumers: on `AsyncError`, treat as "unknown —
  show no badge / keep legacy section state", never crash the page.

### 8. Badge consumer (LEAF B) — contract

- Reads `ref.watch(unifiedUpdatesProvider)` gated by
  `pages.updates.unified`: flag off → badge driven by legacy models
  as today; flag on → badge count = `updates.length`.
- `AsyncLoading` → keep the previous badge count (no flicker);
  `AsyncError` → badge hidden (host-level errors mean nothing
  reliable to count).
- Dedup rule: none in v1 — count rows as returned (see HLD §4).

### 9. Updates-section consumer (LEAF C) — contract

- Reads `ref.watch(unifiedUpdatesProvider)` gated by
  `pages.updates.unified`: flag off → legacy updates section as
  today; flag on → section renders one row per `UpdateInfo`.
- Row data contract: `name` (display title),
  `fromVersion`/`toVersion` (may be null — backends are not required
  to report versions; row must render without them),
  `sizeBytes` (may be null — row must render without it),
  `identity` (opaque — passed to the update-all/action path only,
  never parsed by the UI).
- `AsyncLoading` → skeleton/spinner in the section; `AsyncError` →
  section error state with retry (retry = `ref.invalidate`).
- The section must not import `backend_*`: it receives `UpdateInfo`
  values from the contracts package only.

### 10. Update-all action — contract

- For each `UpdateInfo` in the provider's value, start a host update
  operation for `update.identity` via the host engine
  (`performOperation(OperationKind.update, identity)`), honoring
  `BackendCapability.update` advertisement as the host does today.
- Partial-failure posture: a failed start on one update does not
  abort the others; report per-update outcome where the section
  already has a status row (LEAF C's detail design).
- After the batch reaches terminal state, `ref.invalidate(
  unifiedUpdatesProvider)` to refresh — the provider does not
  auto-refresh on engine activity.
- The host engine is the single source of truth for in-flight state;
  the action does not maintain its own update-set (unlike
  `LocalDebUpdatesModel`'s tracking set — that model retires with
  the legacy path).

### 11. Test matrix

`store_host` (`test/host_test.dart`):

- `pages.updates.unified` defaults to `false` (mirror of the
  `pages.manage.unified` test); unknown keys still never throw.

`app_center` (`test/unified_updates_provider_test.dart`):

- `MapFeatureFlags({'pages.updates.unified': true})` + fake
  `StoreHost` returning canned `UpdateInfo`s → provider resolves to
  the canned list; count and fields (`name`, `fromVersion`,
  `toVersion`, `sizeBytes`, `identity`) flow through unchanged.
- Fake host whose backend throws mid-fan-out → partial results still
  resolve (host degrades, provider passes them through).
- `container.read(provider.future)` pattern per test/AGENTS.md;
  `tearDown(resetAllServices)`; tests live flat in `test/`.

### 12. Out of scope (repeats HLD §4, contract-level)

- Page/badge/section UI migration and the flag flip for real users:
  LEAF B / LEAF C slices, each with their own test coverage.
- Update-all engine orchestration details (queueing, concurrency,
  progress aggregation): the action contract (§10) is the interface;
  the orchestration slice is separate.
- Host fan-out changes, contract version bumps, caching/TTL.
