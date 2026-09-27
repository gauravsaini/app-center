# HLD — One Store Architecture

Parent: [grandvision.md](../grandvision.md) — the *sapna*.
Sibling: [lld.md](lld.md) — interface contracts for every entity.

## 1. Where we stand today

Upstream App Center bakes backends into the app:

```
packages/app_center/lib/
  snapd/        # snapd socket client, snap pages
  deb/          # deb/PackageKit pages
  packagekit/   # PackageKit D-Bus daemon glue
  appstream/    # metadata
  store/ explore/ manage/ search/   # UI wired directly to the above
```

Consequences: adding Flatpak means touching UI, search, manage pages, and
every screen that assumes "snap or deb". Every new format multiplies the
spaghetti. This is exactly what we fix.

## 2. Target architecture

```
┌─────────────────────────────────────────────────────────┐
│                      UI SHELL (Flutter)                  │
│  Explore · Search · App Details · Manage · Settings      │
│  (knows NOTHING about snap/deb/flatpak)                  │
└───────────────────────┬─────────────────────────────────┘
                        │  depends only on contracts
┌───────────────────────▼─────────────────────────────────┐
│                   PLUGIN HOST (core)                     │
│  UnifiedCatalog │ OperationEngine │ PolicyCenter         │
│  FeatureFlags   │ MetadataService │ Telemetry/Benchmarks │
└───┬─────────┬───────────┬─────────────┬─────────────────┘
    │         │           │             │
┌───▼───┐ ┌───▼───┐ ┌─────▼─────┐ ┌─────▼──────┐
│ snap  │ │ deb   │ │ flatpak   │ │ (future)   │  ← backend plugins
│plugin │ │plugin │ │ plugin    │ │ appimage…  │
└───────┘ └───────┘ └───────────┘ └────────────┘
```

**Components:**

- **UI Shell** — pure presentation. Renders `AppInfo`, drives `OperationHandle`,
  reads flags. Zero imports from any backend package. This is the invariant
  that keeps the delta small and the rebase clean.
- **Plugin Host (core)** — owns the contracts (`StoreBackend` interface),
  discovers backends at runtime, fans out search, merges results, queues
  operations, enforces policy.
- **Backend plugins** — one Dart package per format. Each implements
  `StoreBackend`. Each ships its own tests. Each can be enabled/disabled
  independently.
- **UnifiedCatalog** — the brain: parallel search across backends, dedupe
  (same app, three formats → one card, format picker), ranking.
- **OperationEngine** — install/update/remove queue: one operation per app,
  progress streams, cancellation, polkit auth coalescing.
- **MetadataService** — AppStream data, icons, screenshots, ratings/reviews.
  Cached, offline-tolerant.
- **PolicyCenter** — permissions display before install, sandbox badges,
  trust signals. The "better" in libre-and-better lives here.
- **FeatureFlags** — every backend and every risky feature behind a flag.
- **Telemetry/Benchmarks** — startup time, search latency, install success.
  Numbers, not slogans.

## 3. Distribution — thinking like DeepSeek

DeepSeek Harness ships as npm, source, web, desktop — same core, many
vehicles, capability seams per vehicle. We do the same: **one core, many
vehicles, backends detected at runtime.**

**Ship vehicles:**

| Vehicle   | Runs on        | Can manage                              |
|-----------|---------------|------------------------------------------|
| snap      | Ubuntu+       | snap, deb (via pk), flatpak (if present) |
| flatpak   | any distro    | flatpak; snap/deb only via host exec     |
| native deb| Debian/Ubuntu | everything local                         |
| native rpm| Fedora        | dnf backend + flatpak                    |
| AppImage  | any           | flatpak/snap only if host tools exist    |

**Rules that follow:**

1. **Runtime detection, never compile-time assumption.** Each backend exposes
   `isAvailable` (e.g. "is `flatpak` on PATH? is snapd socket live?").
   The host enables what exists. On Fedora, the snap plugin simply sleeps —
   no crash, no empty tab.
2. **Confinement matrix.** A snap-confined store cannot freely shell out to
   `flatpak`; a Flatpak store needs `--talk-name` holes or `flatpak-spawn`.
   Each vehicle documents which backends are reachable and how. The plugin
   contract includes `reachability(vehicle)` so the host never asks a backend
   to do the impossible.
3. **The store updates itself** through its own OperationEngine (dogfooding),
   per vehicle: snap refresh, flatpak update, package manager update.
4. **No vehicle may hard-require a backend.** If only Flatpak exists, the
   store is a great Flatpak store. Degrade gracefully, never refuse to run.

## 4. Feature flags

Every backend and every behavior change ships behind a flag. Taxonomy:

- `backend.<id>.enabled` — kill switch per backend (snap/deb/flatpak/…).
- `catalog.dedupe` — unified cards vs per-format rows.
- `policy.permissions_prompt` — permission screen before install.
- `op.<x>.experimental` — anything half-baked.

**Evaluation layers** (later wins): compiled default → config file
(`~/.config/onestore/flags.yaml`) → env var (`ONESTORE_FLAG_x=1`) →
remote (opt-in only, never required). Flags are readable at runtime;
the UI shows which backend is on/off and why (Settings → Backends).

Why this matters: a broken Flatpak plugin update must be flippable off
without shipping a new build. Flags are the circuit breaker for scale.

## 5. Scaling issues (anticipated, not discovered in prod)

1. **Search fan-out latency.** N backends, slowest wins. Mitigation: per-backend
   timeout (default 3s), **streaming merge** — fast backends render first,
   slow ones append. Never block the UI on the slowest plugin.
2. **Dedupe at scale.** "VLC" exists as deb, snap, flatpak. Identity pipeline:
   exact AppStream ID match → normalized (name + publisher) heuristic →
   community mapping table override. Wrong merges are worse than duplicates —
   bias toward showing two cards over merging wrong.
3. **Update storms.** N backends × M apps polling at launch = CPU spike
   (upstream already had a Manage-page CPU bug — we know this pain).
   Mitigation: staggered background refresh with jitter, per-backend
   incremental checks, results cached with TTL.
4. **Operation conflicts.** Two taps on Install, install-while-updating.
   The OperationEngine owns one state machine per app id; duplicates are
   rejected, not queued twice. Polkit prompts are coalesced per batch.
5. **Ratings/reviews.** Spam and brigading at scale. v1: read-only mirror of
   existing sources; write path comes later with rate limits + moderation
   queue. Don't build the spam problem before the user base.
6. **Icon/screenshot cache.** Thousands of apps × images = disk bloat.
   LRU disk cache with size cap, WebP thumbnails, eviction policy.
7. **Startup cost.** Backend probing must be lazy and parallel — never
   sequential D-Bus calls on the critical path. Target: window visible in
   <1s, backends online within 3s, measured by benchmark gate.

## 6. Key flows

**Search:** UI → UnifiedCatalog.search → parallel `backend.search()` (timeout,
stream) → dedupe via AppIdentity → rank (installed? → rating → name match) →
stream to UI.

**Install:** UI → PolicyCenter (show permissions) → OperationEngine.enqueue →
backend.install → `OperationHandle` (progress stream, cancel) → done/failed →
refresh installed list.

## 7. Migration path (strangler fig)

We do not rewrite upstream. We strangle it:

1. Extract `StoreBackend` contract package; UI untouched.
2. Move `lib/snapd` → `backend_snap` package implementing the contract;
   UI reads through host. Repeat for deb.
3. Add `backend_flatpak` — the first net-new capability, and the proof.
4. Each step ships, each step keeps upstream mergeable. The day a step
   can't rebase cleanly, the delta is too big — shrink it.

## 8. Non-goals (HLD level)

- No new package format of our own. Ever.
- No server we must run for core function. Offline-first.
- No fork of snapd/flatpak themselves — we are a client, not a daemon war.
