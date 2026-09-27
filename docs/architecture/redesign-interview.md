# Redesign Interview: App Center → Libre App Center

> **Setting:** I'm the candidate. The question: *"How would you redesign this?"*
> **Method:** `grill-with-docs` — a relentless interview to sharpen the plan,
> with ADRs and a glossary produced as we go.
> **Constraint given up front:** leverage the DeepSeek plugin model
> (*everything is a plugin*).
>
> This document is the interview transcript **and** the complete HLD + LLD
> for taking the current codebase to the target state.

Related: [grandvision.md](../grandvision.md) · [hld.md](hld.md) · [lld.md](lld.md)

---

## Part 1 — The Grilling

### Q1. Why fork at all? Why not just contribute Flatpak support upstream?

Because the differentiator isn't one feature — it's a product thesis:
**one store, every format, no format favoritism, libre forever.** Upstream's
job is Ubuntu's store, and Canonical has a structural bias toward snap.
That's not an accusation, it's an org chart.

The Brave analogy holds: Brave didn't PR ad-blocking into Chromium. The
product thesis diverged, so they forked and kept the delta small.

But here's the honest part: **if upstream ever adopts our direction, the
fork shrinks to a branding layer — and that's success, not failure.** The
fork is a vehicle for the thesis, not an identity.

### Q2. App-store forks die. Why does this one live?

Blunt answer: they die of **rebase tax + no distribution**. Our mitigations:

1. **Strangler-fig migration** — new work lands in *new* packages, not in
   upstream's files. Conflicts concentrate in one thin host layer.
2. **Contract tests** — rebases become mechanically verifiable, not
   prayer-based.
3. **Weekly rebase-dry-run CI** — merge upstream into scratch, run the exam;
   green means a human fast-forwards, red means an isolated, named conflict.
4. **Distribution from day one** — Flathub + PPA + AUR, not "we'll figure out
   shipping later."

The moat isn't code. It's the **plugin ecosystem + community index**
(grandvision Phase 3). If we only ever ship "App Center + Flatpak tab," we
die on schedule. The architecture must let strangers add backends we never
imagined — that's the only durable advantage.

### Q3. Plugins mean indirection. Prove the overhead is worth it.

The indirection costs one interface dispatch per call — unmeasurable next to
backend latency (D-Bus round-trips are milliseconds, `flatpak search` is
seconds). The payoff:

- A new backend ≈ 1 package, ~2k lines, **zero UI changes**.
- Broken backend? Kill-switch it via flag; the store still runs.
- Every backend gets a conformance suite for free (the contract exam).

When it does **not** pay off: if we only ever have 2 backends and never a
third — then it's over-engineering. Our bet, stated plainly: the \*nix world
has 7+ formats, so 3 is the floor, not the ceiling. If we're wrong, the
plugin layer is still thin enough to delete.

### Q4. Same app in three formats — what does the user actually see?

**One card.** Format picker inside, like choosing a download mirror.

- Default format: `catalog.backend_order` flag, overridden by "already
  installed in format X" (installed state always wins).
- Dedupe pipeline: exact AppStream ID → normalized `name+publisher`
  heuristic → community override table.
- **Bias rule: show two cards rather than merge wrong.** A wrong merge
  installs the wrong thing (harmful); a duplicate card is merely ugly.

### Q5. A backend lies, hangs, or dies mid-install. Then what?

- Hang: per-backend timeout (3s search). The catalog degrades to a
  "partial results" badge — one slow backend never fails the whole search.
- Die mid-operation: handle → `failed(BackendUnavailableException)`.
  Circuit breaker: 3 failures → backend auto-disabled, user-visible note,
  flaggable back on.
- Partial install: each backend's `remove` is the rollback. The engine
  offers "clean up partial install" — never silent, never automatic
  destructive action without consent.
- Lie (bad metadata): metadata is untrusted input. The host validates,
  truncates, and never executes anything from it.

### Q6. "Small delta" sounds nice in a doc. How do you enforce it in practice?

1. **Dependency arrows as law** — CI import lint: UI may not import any
   `backend_*` package. If the build passes, the layering held.
2. **New code in new packages.** Touching upstream's files is a code-review
   red flag requiring justification.
3. **The rebase rule:** if a feature can't survive a rebase, it was built in
   the wrong layer — move it, don't patch around it.
4. **Delta dashboard:** weekly CI reports diffstat of our branch vs
   upstream. If it grows, we have a conversation — with ourselves.

### Q7. N backends probing at startup — how do you stay under 1 second?

- `isAvailable()` contract: <200ms, side-effect free, all backends probed
  **in parallel**, off the critical path.
- Window renders from cache immediately (last-known installed list, cached
  catalog). Backends come online within 3s; the UI shows them arriving.
- Update checks: staggered background with jitter, TTL-cached — never on
  launch path. (Upstream already had a Manage-page CPU bug. We know this
  pain personally.)
- **Benchmark gate in CI:** cold start p50 <1s to window, <3s to interactive
  backends, scripted harness. Regressions fail the build.

### Q8. One store driving snapd (root) + PackageKit (polkit) + flatpak — what's the trust model?

1. **Least privilege per vehicle.** The Flatpak vehicle can't do what native
   can — and the UI says so honestly instead of pretending.
2. **Polkit is never bypassed or auto-accepted.** Batched auth shows exactly
   what will happen, in plain language, before the prompt.
3. **Permissions before install**, from backend manifests — the PolicyCenter
   is the "better" in libre-and-better.
4. **Network minimalism:** metadata/ratings mirrors only, all opt-out-able.
   No analytics without explicit opt-in.
5. **Supply chain:** reproducible builds, signed releases, no curl-piped
   installers as the primary path.

We never ask for trust we don't need, and we show our work.

### Q9. Won't feature flags become a second config hell?

Rules, enforced:

- Flags are booleans or short enums. Nothing else.
- Every flag has an **owner, a default, and a removal date**. Flags are tech
  debt with a TTL — experimental flags graduate or die within 2 releases.
- `flagState()` explains *why* a flag is off ("killed by flag" vs
  "flatpak not found") — visible in Settings → Backends.
- CI fails on unknown flag keys.
- If flags ever need more UI than a list, we've failed — keep the surface tiny.

### Q10. What's the first vertical slice, and what do you explicitly NOT build?

**Ship:** Flatpak backend end-to-end — search → details → install → manage →
update → remove — behind `backend.flatpak.enabled`, Ubuntu only. It's the
smallest proof of the *entire* architecture (new package, zero UI changes,
contract exam green) and the biggest user-visible win.

**Explicitly NOT building:** ratings write path, community index,
non-Ubuntu vehicles, AppImage, the store's self-update story. One slice,
done right, measured. Everything else is a GitHub issue, not a branch.

### Q11. How do you measure "better"? Give me numbers.

CI-gated, opt-in telemetry, no slogans:

- Cold start p50 < 1s (window), < 3s (backends interactive)
- Keystroke → first search result < 300ms
- Install success rate > 99.5%
- Crash-free sessions > 99.9%
- Internal health: rebase conflicts per week, trending down

"Better experience" without numbers is marketing. We ship numbers.

### Q12. Distribution — how does this reach a user's machine?

Phase 0: **Flathub** (every distro, one build) + PPA/deb for Ubuntu + AUR.
Phase 1: Fedora COPR, Nix flake. The store must install with one command on
any major distro — we dogfood the dream from day one. No distro partnership
required to start; partnerships are Phase 2 leverage, not a dependency.

---

## Part 2 — Domain Modeling

Ubiquitous language. If a backend author needs to ask what a word means,
the model failed.

### Glossary

| Term | Definition |
|---|---|
| **Backend** | A plugin implementing `StoreBackend` for one package format (snap, deb, flatpak). The only unit that knows format specifics. |
| **Host** | The core layer owning contracts, catalog, operation engine, flags. Knows no format specifics. |
| **UI Shell** | The Flutter presentation layer. May depend on contracts + host only. Backend-blind by law. |
| **Contract** | The `StoreBackend` interface + entities + error taxonomy in `store_contracts`. Versioned SemVer. The law. |
| **Capability** | A declared power of a backend (`search`, `install`, `permissions`…). The host checks, never assumes. |
| **AppIdentity** | Globally unique app key: `backendId:nativeId` (e.g. `flatpak:org.videolan.VLC`). |
| **UnifiedApp** | One or more `AppInfo`s from different backends judged to be the same app. Renders as one card. |
| **Dedupe** | The pipeline grouping `AppInfo`s into `UnifiedApp`s (AppStream ID → heuristic → override table). |
| **Operation** | One install/update/remove run, represented by an `OperationHandle` with a monotonic state machine ending in done/cancelled/failed. |
| **OperationEngine** | Host service owning all operations: one active op per app, progress, cancellation, auth batching. |
| **Vehicle** | How the store itself was installed (snap, flatpak, native deb/rpm, AppImage). Determines backend reachability. |
| **Reachability** | Whether a backend can work in the current vehicle: direct, via host-exec bridge, or unavailable. |
| **Flag** | A named boolean/enum switch (`backend.flatpak.enabled`) with layered evaluation and a TTL. |
| **Kill switch** | The `backend.<id>.enabled` flag family — disables a backend without a new build. |
| **Contract exam** | The conformance test suite in `store_contracts` every backend must pass to ship. |
| **Rebase tax** | The recurring cost of merging upstream. Minimized by strangler-fig layering; tracked weekly. |
| **Strangler fig** | Migration pattern: new architecture grows around the old code, which is extracted piece by piece — never a big-bang rewrite. |
| **Beachhead** | Phase 0 scope: Ubuntu + snap/deb/flatpak. The smallest defensible territory. |

### Entity map

```
StoreBackend (1) ──implements──▶ BackendCapability (*)
     │
     ├──produces──▶ AppInfo (*) ──grouped by dedupe──▶ UnifiedApp (*)
     │                      │
     │                      └──detail──▶ AppDetails (1) ──declares──▶ Permission (*)
     │
     └──executes──▶ OperationHandle (1 per op) ──transitions──▶ OperationState
                                                        │
                                                        └──fails with──▶ StoreException

Host services: UnifiedCatalog · OperationEngine · FeatureFlags ·
               MetadataService · PolicyCenter · Telemetry
```

---

## Part 3 — ADRs

### ADR-1: Fork (Brave model) over upstream-only contribution
**Decision:** Maintain a fork with a minimal, reviewable delta; rebase continuously.
**Rationale:** The product thesis (format-neutral, plugin-based, libre-first) diverges from upstream's Ubuntu/snap-centric mandate. A fork moves at our speed.
**Consequence:** Rebase tax is real; mitigated by ADR-4/5/6. If upstream converges, the fork shrinks — that's winning.

### ADR-2: Everything-is-a-plugin (DeepSeek Harness model)
**Decision:** Every package format is a backend plugin behind `StoreBackend`; the UI is backend-blind.
**Rationale:** N formats can't be if-elsed. Plugins make backends addable, kill-switchable, and independently testable.
**Consequence:** Thin indirection layer; contract discipline required (the exam).

### ADR-3: Runtime backend detection, never compile-time assumption
**Decision:** Backends probe `isAvailable()` at startup; the store adapts to the distro it's on.
**Rationale:** One core, many vehicles/distros. A store that refuses to run without snap is a non-starter on Fedora.
**Consequence:** UI must handle "backend absent" as a normal state, not an error.

### ADR-4: Strangler-fig migration, no big-bang rewrite
**Decision:** Extract `lib/snapd` → `backend_snap`, `lib/deb` → `backend_deb` package by package; UI migrates to contracts incrementally.
**Rationale:** Every step ships and stays rebaseable. Big-bang rewrites die in branches.
**Consequence:** Temporary duplication during migration; each extraction is its own reviewable commit.

### ADR-5: Dedupe bias — duplicates over wrong merges
**Decision:** When identity is uncertain, show two cards rather than merge.
**Rationale:** A wrong merge installs the wrong software (harmful); a duplicate is cosmetic.
**Consequence:** Occasional duplicate cards until the override table catches up — acceptable, visible, fixable by the community.

### ADR-6: Operations as cancellable state machines with typed errors
**Decision:** `OperationHandle` with monotonic states; all failures are `StoreException` subtypes; cancel ≤2s.
**Rationale:** Install UX is trust UX. Users must always see what's happening, be able to stop it, and get an actionable error — never raw stderr.
**Consequence:** Backends do real work to map native errors into the taxonomy. No lazy `catch (e)`.

### ADR-7: Feature flags with layers and TTLs
**Decision:** Every backend and risky behavior behind flags; layers (default → file → env → remote); every flag has owner + removal date.
**Rationale:** Kill switches are the circuit breaker for a plugin system; TTLs prevent config hell.
**Consequence:** Flag hygiene is a review checklist item.

### ADR-8: Benchmarks as CI gates
**Decision:** Startup, search latency, and install success are measured in CI; regressions fail the build.
**Rationale:** "Better" is a number or it didn't happen. Performance is a feature, and features need tests.
**Consequence:** Benchmark harness maintenance is real work, budgeted from day one.

### ADR-9: GPL-3.0, no CLA
**Decision:** Keep upstream's GPL-3.0; no contributor license agreement that reassigns rights.
**Rationale:** "Libre forever" must be structural, not a promise. Anyone can fork us — including away from us if we go wrong.
**Consequence:** Some corporate contributors may hesitate. Acceptable trade for trust.

### ADR-10: Offline-first, no mandatory server
**Decision:** Core function (search installed, install, update) works offline from local backend data; metadata degrades to cache.
**Rationale:** A store that needs our server is a store we can take away. Libre means self-sufficient.
**Consequence:** No server-side personalization; ranking stays local and explainable.

---

## Part 4 — The Redesign: Current → Target

### 4.1 Current state (what exists today)

Upstream App Center (`ubuntu/app-center`, Flutter/Dart, melos monorepo):

- `packages/app_center/lib/snapd/` — snapd socket client + snap UI pages
- `packages/app_center/lib/deb/` + `lib/packagekit/` — deb via PackageKit
- `packages/app_center/lib/{explore,search,manage}/` — UI wired **directly**
  to the backend dirs above
- `packages/app_center_ratings_client/` — gRPC ratings
- `packagekit-session-installer/` — C D-Bus daemon

The architecture is **two backends baked into one app**. Every screen knows
about snap-vs-deb. Adding a third format means editing N screens. This is
the core problem the redesign solves — everything else follows.

### 4.2 Target state (HLD)

```
┌─────────────────────────────────────────────────────────┐
│ UI SHELL — Explore · Search · Details · Manage          │
│ (imports: flutter, store_contracts, store_host — ONLY)  │
└───────────────────────┬─────────────────────────────────┘
┌───────────────────────▼─────────────────────────────────┐
│ HOST — UnifiedCatalog · OperationEngine · FeatureFlags  │
│        MetadataService · PolicyCenter · Telemetry       │
└───┬─────────┬───────────┬─────────────┬─────────────────┘
┌───▼───┐ ┌───▼───┐ ┌─────▼─────┐ ┌─────▼──────┐
│ snap  │ │ deb   │ │ flatpak   │ │ future…    │  backend plugins
└───────┘ └───────┘ └───────────┘ └────────────┘
```

Melos packages: `store_contracts` (the law) → `store_host` (services) →
`backend_snap`, `backend_deb`, `backend_flatpak` → `app_center` (UI shell).
CI import lint enforces the arrows.

Distribution: one core, many vehicles (snap/flatpak/native deb/rpm/AppImage);
backends detected at runtime via `isAvailable()`; confinement matrix per
vehicle; the store degrades gracefully, never refuses to run.

### 4.3 Target state (LLD — contracts summary)

Full contracts: [lld.md](lld.md). The load-bearing ones:

- **`StoreBackend`** — `id`, `capabilities`, `isAvailable()` (<200ms),
  `reachability(vehicle)`, streaming `search()`, `getDetails()`,
  `getInstalled()`, `checkUpdates()`, `install()/remove()/update()` returning
  `OperationHandle`. Pre/post conditions, timeouts, idempotency per method.
- **Entities** — `AppInfo`/`AppDetails`/`AppIdentity` (freezed, normalized,
  no null-garbage); `Permission` with levels for the pre-install screen.
- **`OperationHandle`** — monotonic state machine
  (queued → … → done|cancelled|failed), typed `StoreException` on failure,
  `cancel()` safe in any state, ≤2s to terminal.
- **`UnifiedCatalog`** — parallel fan-out, 3s per-backend timeout, streaming
  merge, dedupe pipeline, deterministic explainable ranking.
- **`OperationEngine`** — one active op per `AppIdentity` (second enqueue
  returns the existing handle), polkit batching, active-ops stream for
  the Manage page.
- **`FeatureFlags`** — `backend.<id>.enabled` kill switches; layers
  default → file → env → remote; `flagState()` explains why.
- **`StoreException`** — sealed taxonomy (network/auth/disk/unavailable/
  not-found/conflict/unknown); backends map native errors into it.
- **Contract exam** — conformance suite in `store_contracts`; a backend that
  fails doesn't ship. **Interface SemVer** — additive = minor, breaking =
  major, host refuses mismatched majors loudly.

### 4.4 Migration: the strangler fig, step by step

| Step | Work | Proof it's done |
|---|---|---|
| 0 | `store_contracts` package: interfaces + entities + exceptions + exam (empty impls) | `melos test` green; nothing imports it yet |
| 1 | `store_host`: UnifiedCatalog + OperationEngine + FeatureFlags over the contracts, with **adapter shims** over current `lib/snapd`, `lib/deb` code | Existing UI works unchanged; host covered by tests |
| 2 | Extract `lib/snapd` → `backend_snap` implementing `StoreBackend`; UI reads through host | Snap flows green; `lib/snapd` deleted |
| 3 | Extract `lib/deb`+`lib/packagekit` glue → `backend_deb` | Deb flows green; old dirs deleted |
| 4 | **First vertical slice:** `backend_flatpak` — search→details→install→manage→update→remove behind flag | Contract exam green; dogfood on Ubuntu |
| 5 | PolicyCenter (permissions screen), benchmark gates in CI | Numbers on the dashboard |
| 6 | Rebase-dry-run CI weekly; delta dashboard | Rebase tax visible and shrinking |

Each step ships. Each step keeps `git merge upstream/main` boring. The day
a step isn't boring, the delta grew too big — shrink the step, not the ambition.

### 4.5 What "done" looks like for Phase 0

A user on stock Ubuntu opens Libre App Center, searches "VLC", sees **one**
card with a format picker (deb/snap/flatpak), sees permissions before
installing, installs with one tap, cancels mid-download if they change their
mind, and updates everything from one Manage page. Cold start under a second.
And `git log upstream/main..HEAD --stat` fits on one screen.

---

*Interview closed. The plan survived the grilling with its architecture
intact and its scope smaller — which is exactly what grilling is for.*
