# Phase 3 Identity — HLD: "One App, One Card"

## 1. Problem

Today Firefox is up to six cards: `snap:firefox`, `deb:firefox`,
`flatpak:org.mozilla.firefox`, `appimage:<sha256>`, `rpm:firefox;136.0-1…`,
`pacman:firefox;146.0-1…`. The host's v1 grouping policy is one
`UnifiedApp` per `AppInfo` — no cross-backend merging, ever, because the
standing rule forbids faking the merge with name heuristics. The product
thesis (grandvision.md) says duplicate cards are a bug: *"No one should
ever see 'VLC' three times."*

The missing piece is not UI. It is **knowledge**: nothing in the system
records that `deb:firefox` and `flatpak:org.mozilla.firefox` are the same
upstream project. Phase 3 builds that knowledge layer properly — a
canonical identity model plus a local, community-ownable metadata index.

## 2. Key insight

Upstream projects **already have cross-format identifiers**. We do not
need to invent them, match on names, or guess:

- **AppStream component IDs** (`org.mozilla.firefox`) are the cross-distro
  app identifier designed for exactly this. Flathub app IDs match them by
  policy; Debian's AppStream catalog uses them; the snap store carries them.
  The flatpak backend's reverse-DNS IDs are AppStream IDs in practice.
- **Homepage URLs** are the second cross-format signal. rpm and pacman
  already surface them (`AppDetails.homepage`); deb's PackageKit and
  flatpak's `flatpak info` emit them at the wire level today (unparsed —
  harvesting them is a later slice).

What is missing is **a place to record the mapping**. That place is the
identity index. The grand vision's Phase 3 "community-owned metadata
index" starts here — as a local identity index whose serialization format
is designed from day one to be publishable, shareable, and community-
curated.

## 3. Canonical identity model

### 3.1 `CanonicalAppId`

A value type: `scheme:value`. Two schemes, deliberately few:

- `appstream:<component-id>` — primary. Used when an AppStream component
  ID is known (e.g. `appstream:org.mozilla.firefox`).
- `homepage:<normalized-host-and-path>` — fallback. Used when only a
  homepage is known and no AppStream ID exists.

There is **no `name:` scheme**. A bare name is never an identity — this is
the standing rule, encoded in the type system. If you cannot name the
scheme, you do not have an identity.

### 3.2 What counts as "the same app"

Ranked, deterministic, no heuristics:

1. **Curated index mapping.** A human-verified `(backendId, lookupKey) →
   canonicalId` entry. Highest precedence in the resolver *because* it is
   verified — curation outranks automation.
2. **Exact AppStream component ID match.** A backend-reported AppStream ID
   that equals an index entry's AppStream ID.
3. **Normalized homepage URL match.** Same normalization on both sides
   (§3.3); exact match only.

**Explicit non-goals, forever:** name equality, fuzzy/approximate name
matching, vendor-domain-prefix inference on its own, "similar description"
matching. If the index has no entry and no signal matches, the app is
**unresolved** — and unresolved degrades to today's behavior (one card per
backend). An honest duplicate beats a wrong merge.

### 3.3 Homepage normalization

`normalizeHomepage(url)`: strip scheme; lowercase host; strip leading
`www.`; drop query and fragment; strip trailing slash; keep path (empty
path → host only). Examples:

- `https://www.mozilla.org/en-US/firefox/` → `mozilla.org/en-US/firefox`
- `http://videolan.org/vlc/` → `videolan.org/vlc`

Path is kept because `mozilla.org` alone cannot distinguish Firefox from
Thunderbird. Normalization is total (never throws; garbage in → a
stable garbage key that simply never matches).

### 3.4 Conflict policy

Signals can disagree: a backend reports AppStream ID X while its homepage
matches entry Y. The resolver is deterministic:

- Curated backend-key mapping beats everything.
- AppStream signal beats homepage signal.
- The choice is documented and unit-tested; conflicts never throw.

A wrong-but-deterministic merge is still wrong — which is why curated
mappings outrank signals, and why unresolved is always a legal answer.

## 4. The identity index

### 4.1 Local-first

The index is a **JSON document**, schema-versioned (`schemaVersion: 1`).
Query patterns are simple key lookups — `(backendId, lookupKey) →
canonicalId` and `canonicalId → entry` — over thousands of entries, not
millions. SQLite would add a native dependency for no query-planning win;
JSON **is** the interchange format the community future needs, so the
storage format and the shareable format are the same thing. Zero native
deps, works offline, trivially diffable.

### 4.2 Layered loading

Three layers, lowest priority first; higher layers win:

1. **Bundled seed** — hand-curated, shipped with the app. Small (~18
   well-known apps), honest about incompleteness. Proves the pipeline.
2. **Local overlay** — user/community additions on disk. Survives updates.
3. **Community download** (future slice) — signed, mirrored, owned by no
   one.

Merge semantics per canonical ID: the higher layer's entry wins, except
signal lists (`appstreamIds`, `homepages`, backend key lists) which
**union** — signals accumulate; curated fields get replaced. `aliases`
union with higher-layer-wins on conflict.

### 4.3 Schema (v1) — the community interchange format

Designed now, networked later. Canonical JSON: stable key ordering,
`schemaVersion`, `generatedAt`, per-entry `provenance {source, updatedAt}`.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-27T00:00:00Z",
  "source": "libreapp-center-seed",
  "entries": [
    {
      "canonicalId": "appstream:org.mozilla.firefox",
      "displayName": "Firefox",
      "appstreamIds": ["org.mozilla.firefox"],
      "homepages": ["mozilla.org/firefox"],
      "backends": {
        "snap": ["firefox"],
        "deb": ["firefox"],
        "flatpak": ["org.mozilla.firefox"],
        "rpm": ["firefox"],
        "pacman": ["firefox"]
      },
      "provenance": {"source": "seed", "updatedAt": "2026-09-27T00:00:00Z"}
    }
  ],
  "aliases": { "homepage:mozilla.org/firefox": "appstream:org.mozilla.firefox" }
}
```

Notes:

- `backends` keys are **identity lookup keys**, not raw native IDs —
  rpm/pacman store arch-agnostic names (see §5), because the app is the
  same app on every arch.
- `aliases` handles canonical-ID migration: when an entry gains an
  AppStream ID, its old `homepage:` ID becomes an alias, never a dead link.
- A `signature` field is **reserved** for the signed-community-download
  slice; v1 readers ignore unknown fields (forward compatibility is a
  schema requirement, not a hope).

### 4.4 Seeding

Slice 1 seeds from **hand curation only**: ~18 apps where snap name, deb
name, flatpak ID, homepage, and AppStream ID are all confidently known.
No scraping, no guessing. Future slices harvest AppStream catalogs per
backend (`/usr/share/app-info`, flatpak appstream, snap store metadata) —
but harvested data enters as *signals*, never as curated mappings, until
verified.

### 4.5 Update mechanism

The file store watches nothing in slice 1. On startup: load seed, overlay
local files if newer, merge. `saveOverlay` writes user additions. The
community-download slice adds: fetch → verify signature → replace layer 3
→ re-merge. The layered design means that slice touches only the loader,
not the index or resolver.

## 5. Backend lookup keys — identity ≠ card

Backends own their ID structures, so each backend owns its normalization:

- New additive `StoreBackend.identityLookupKey(AppIdentity)` (default:
  `nativeId`). Contract minor bump 0.2.0 → 0.3.0 — additive with a
  default, majors untouched, all backends keep compiling.
- **rpm** overrides → bare package name. Its card key is `name.arch`, but
  `firefox.x86_64` and `firefox.aarch64` are the *same app* — identity is
  arch-agnostic by definition.
- **pacman** overrides → bare name (same as its card key).
- **appimage** keeps the default (content hash). Consequence, stated
  honestly: the index can only map *known* hashes — resolution is exact-
  hash match against curated entries, i.e. a catalog lookup, never a
  heuristic. Unknown hash → unresolved. This is the correct behavior for
  a format with no registry.

## 6. Merge policy — defined now, UI in slice 2

When one canonical app has N backend sources, the merged card resolves
sources in this order:

1. **Installed source wins.** If the user installed it via snap, the snap
   variant is the truth for actions (update/remove target the installed
   thing).
2. **User preference.** A per-app remembered choice (slice 2 setting).
3. **Flag order.** `catalog.backend_order` (exists today; extended to all
   six backends).
4. **First available.**

The merged card shows a format picker across all sources — `AppSource`
already exists *"for badges and the format picker"*. Install always acts
on the resolved source; the picker lets the user switch.

## 7. Migration path

- `StoreHost.resolveIdentity()` is **additive** and gated by
  `phase3.identity.enabled` (default off, ADR-010 owner + removal date).
- Flag off, or resolver returns null (unresolved) → **today's behavior,
  bit for bit**: one card per backend, v1 grouping untouched.
- Slice 1 changes **no** install/update/search behavior and **no** UI.
  It lays the types, the index, the resolver, and the seed — the
  foundation slice 2 (signal harvesting + merged cards) builds on.

## 8. What this slice does NOT do (explicit)

- No UI changes. No `UnifiedApp.canonicalId` field yet (slice 2).
- No per-backend signal harvesting (reading snap publisher, deb
  PackageKit `url`, flatpak `Homepage`) — slice 2.
- No community download, no signatures, no mirroring — later.
- No fuzzy matching. Ever. (Restated because it matters most.)
