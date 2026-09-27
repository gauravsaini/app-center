# Phase 3 slice 4 — identity index + preference reload polish

Leaf-scoped notes for the Phase 3 slice 4 work. Each leaf owns its
section; the coordinator assembles the merge.

## Settings UI: "App identity" section + community refresh UX (Leaf A)

Companion to `phase3-slice2.md` (§5 UI contract) and `phase3-slice3.md`
(§4–§5 flags, refresh flow, result type). Covers only what was genuinely
undecided: where the section lives, the refresh UX states, the toggle-on
invalidation path, where the last-refresh timestamp persists, and the
interface Leaf B must provide for the refresh seam.

### 1. Where the section lives: a new "Settings" sidebar page

No settings page existed — `store_pages.dart` had Explore / snap-category
tiles / Games / Manage / About, and no backend-enable toggles anywhere in
the UI (`backendEnabledProvider` is nav-visibility only). So there was no
pattern to follow; one had to be chosen:

- **Chosen: new `SettingsPage` as a sidebar tile**, appended after the
  About tile in `storePagesProvider`. The page renders one
  `YaruSection` titled "App identity" (CustomScrollView pattern copied
  from `AboutPage`). Appending at the end keeps every existing page index
  stable (`yaruPageControllerProvider` length grows by one, no reorder).
- Rejected: a gear-icon `/settings` route — there is no existing entry
  point to hang it on, and the sidebar page is one tile, no route
  plumbing, no navigator changes.
- Rejected: putting the section inside About — wrong semantics; About is
  product info, this is user control.

Settings page files: `packages/app_center/lib/settings/` (`settings_page.dart`,
`identity_settings.dart` for the section widget + providers,
`community_refresh_store.dart` for persistence). No `backend_*` imports
anywhere in the slice — UI sees `store_host`/`store_contracts` only.

### 2. Refresh UX states

`StoreHost.refreshCommunityIndex()` is a single `Future` — the host
exposes **no per-phase progress** (no callbacks, no stream). So the
"checking/downloading/verifying" granularity from the task brief cannot
be driven by real host signals, and faking phased progress would be
dishonest UI. Decision:

```
idle → checking → up-to-date | failed(reason) | skipped(reason)
```

- **checking** is one indeterminate state, labeled "Contacting mirrors…"
  (never "Downloading 42%" — we don't know).
- **up-to-date** (result `ok`): entry count + winning mirror + doc
  `generatedAt` (informational staleness display, per the result-type
  contract — never a freshness gate).
- **failed** (result `failed`): the per-mirror error strings from
  `errorsByMirror`, verbatim. The host contract guarantees they are
  message-only (no secrets), so verbatim display is safe.
- **skipped** (result `skipped`): the host's `reason` verbatim
  (e.g. community disabled, mirrors empty). This is the *expected* state
  for a fresh install — the section must read sensibly with everything
  off: toggle off → refresh reports skipped with the gate reason, no
  error styling, no throw.

The notifier wraps the host call in try/catch → `failed` so a UI-side
refresh **never throws**, even if the host's never-throws guarantee
regresses.

### 3. Toggle-on behavior: re-resolve + re-render without restart

`MapFeatureFlags.setFlag` mutates in place and emits on `changes`, but
Riverpod providers don't watch that stream — `identityEnabledProvider`
is a sync read of the flags instance. So the toggle handler does:

```dart
(flags as MapFeatureFlags).setFlag('phase3.identity.enabled', value);
ref.invalidate(identityEnabledProvider);
ref.invalidate(unifiedSearchProvider);          // all family instances
ref.invalidate(unifiedInstalledResultProvider);
```

This works because the host reads `phase3.identity.enabled` **at call
time** — Leaf B verified in code above (this doc, "Runtime identity
toggle") that `search()`/`installedDetailed()` never cache merged
results across calls. Re-running the search providers re-fans-out over
the backends with the flag on, the host merges by canonical id, and the
cards rebuild with `canonicalId` set — no restart, no host rebuild.
Factored as a top-level `setIdentityEnabled(WidgetRef ref, bool value)`
so widget tests drive the exact production code path. (Leaf B's note
says no UI-side invalidation is required *for correctness of the host*;
the UI-side invalidation here is for *freshness of displayed lists* —
dropping the providers' cached unmerged results so the new merged
results are fetched.)

Invalidation scope is deliberately narrow: search + installed listings
are the only surfaces that merge. Updates (`unifiedUpdatesProvider`)
don't render merged cards and keep their own refresh lifecycle.

### 4. Last-refresh timestamp: UI-side persistence (decision)

The task offered "a small host-internal store or the preference store
file". Both are host-owned (Leaf B's lane). Decision: **UI-side
persistence** — `CommunityRefreshStore` in `lib/settings/`, a tiny JSON
file at `xdg.dataHome/libreapp-center/community-refresh.json`
(`~/.local/share/libreapp-center/`, same convention as the host's layer
files; `xdg_directories` is already a dependency):

```json
{"lastAttempt": "2026-09-28T01:30:00.000Z", "lastOk": "...",
 "mirror": "https://...", "entryCount": 128}
```

Rationale: this is *UI state* ("when did the user last tap refresh and
what happened"), not host state — and it records failed attempts too,
which a host layer-file mtime cannot. Load never throws
(corrupt/missing → null); save is best-effort (never throws). Base
directory is injectable for tests.

### 5. Honest-copy rules (enforced in review, not just intent)

- Signature row shows **"Signature valid — key `<keyId>`"**, never
  "verified safe". The explainer states what a signature actually
  proves: the doc came from the holder of the pinned curator key. It
  does **not** prove the mappings are correct or safe (slice 3 §8: a
  compromised curator key can mislabel apps until an app update rotates
  it; no in-band revocation in v1).
- The section states the index is **community-curated**, refresh is
  **manual-only** (no auto-download anywhere — host structural
  property), and mirrors are operator-set (count shown; no editing UI
  in this slice — editing an operator trust decision doesn't belong in
  a v1 settings page).
- Default stays OFF for both `phase3.identity.enabled` and
  `phase3.community.enabled`: explicit opt-in, ADR-010.

### 6. Interface from Leaf B (host changes — LANDED)

`CommunityRefreshResult`, `CommunityIndexTransport`, and
`VerifiedCommunityDoc` were deliberately not exported from
`store_host.dart` ("host-internal plumbing"). The settings UI needed
three additive host changes, all landed on this branch
(`feat(store-host): export community refresh types + keyId on refresh
ok`):

1. **Barrel exports** in `packages/store_host/lib/store_host.dart`:
   `src/identity/community_refresh.dart` and
   `src/identity/community_transport.dart` — the minimal pair the
   Settings UI needs (result types + transport interface for the
   test seam). No crypto export: the widget ok-path test uses a fake
   `StoreHost` subclass returning a canned `CommunityRefreshResult.ok`,
   so no signing or trust-store types leak into the UI layer.
2. **Additive `keyId` on `CommunityRefreshResult.ok`** (required
   named param; the host passes `verified.keyId` at its single
   construction site). The UI shows it as "Signature valid — key
   `<keyId>`".

With the exports in place, the UI names the types directly, and the
test seams are `communityTransportOverrideProvider` /
`communityTrustOverrideProvider` (both null in production — the host
then uses `HttpCommunityIndexTransport` /
`CommunityTrustStore.bootstrap`; scripted fakes in tests). The
fake-transport ok-path widget test drives a signed doc through the
real host: fake transport serves it, ephemeral trust verifies it,
result `ok` → up-to-date state.

## Preference reload contract (Leaf B)

`SourcePreferenceStore` (phase3-slice2.md §4) loaded once per host
lifetime in slice 2 — an honest gap (slice 2 §4: "no reload API").
Slice 4 closes it with the same reload shape slice 3 gave the
identity index (phase3-slice3.md §6).

### API

- `void StoreHost.reloadSourcePreferences()` — drops the cached
  preference map. The next preference read (`getPreferredSource` /
  any merge) rebuilds the store from disk. Never throws: worst case
  the next load yields empty preferences (`load` never throws).
- `Future<String?> StoreHost.getPreferredSource(CanonicalAppId id)` —
  the remembered backend id, or null. Reads the in-memory cache.
- `Future<void> StoreHost.setPreferredSource(CanonicalAppId id, String
  backendId)` — unchanged signature; now documented write-through.

### Semantics

- **Reload contract (same shape as `reloadIdentityIndex`):** the swap
  replaces the immutable `SourcePreferenceStore` reference, so
  in-flight merges finish on the old store — no tearing, no locks.
- **`setPreferredSource` is write-through AND in-memory atomic:** the
  in-memory map updates *before* the disk write, so set → immediate
  read-back is consistent without calling `reloadSourcePreferences`.
  If the disk write throws `StateError` (unrecoverable I/O only —
  disk full, permission denied), the in-memory value still stands:
  the current process stays consistent; the next process start
  re-reads from disk.
- **Independent caches:** `reloadSourcePreferences` touches only the
  preference store; `reloadIdentityIndex` touches only the identity
  index. Neither clobbers the other.
- **File forgiveness lives at the load layer** (as in slice 3):
  missing / unreadable / unparseable / non-map JSON → empty
  preferences, never a throw. `setPreferred` throws `StateError`
  (with the path in the message) only on unrecoverable I/O.

### Runtime identity toggle (verified in code, pinned by test)

`search()` and `installedDetailed()` read `phase3.identity.enabled`
**at call time** (per call, never cached). Resolution itself happens
per call inside `_mergeByIdentity` → `resolveIdentity` — merged
results are never cached across calls. So flipping the flag
false→true→false at runtime takes effect on the very next call, no
restart and no host-side invalidation needed:

- flag off → `search()` emits one card per backend result
  (`canonicalId == null`), exactly the v1 grouping;
- flag on → the next `search()` buffers, resolves, and merges into
  one canonical card;
- flag back off → the next `search()` is unmerged again.

The cached identity index/resolver (if already built) stays in
memory across the flip — harmless: `resolveIdentity` returns null
before touching the cache when the flag is off, and reuse of the
cache when the flag comes back on is correct (no per-flag state in
it). No UI-side invalidation is required for the toggle; the only
thing the UI must NOT do is cache merged `UnifiedApp` lists itself
across the toggle.
