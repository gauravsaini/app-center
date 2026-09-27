# Phase 3 Slice 5 — Community Metadata: Descriptions, Screenshots, Permissions, Ratings

Companion to `phase3-identity-hld.md` / `phase3-identity-lld.md` /
`phase3-slice2.md` / `phase3-slice3.md` / `phase3-slice4.md`. Slices 1–4
built canonical identity, merged cards, the signed community *identity*
distribution channel, and the identity settings UX. This slice extends
the community index from identity MAPPINGS to app METADATA — the grand
vision's Phase 3 "index": *"screenshots, descriptions, ratings,
permissions — owned by no one, mirrored by everyone."*

This note covers only what was genuinely undecided: the metadata
schema (and the permission vocabulary, which is the hard problem), the
distribution choice (new doc vs. extend), the UI precedence contract,
the flags, and the threat model. Everything decided here is designed
before code, in the slice-3/4 style: additive only, no contract breaks,
honest about what's lossy.

## 1. Metadata schema: `community-metadata` doc

One JSON document, `schemaVersion: 1`, `docType: 'community-metadata'`
(the `docType` discriminator is new — see §2 for why). Top level:

```json
{
  "schemaVersion": 1,
  "docType": "community-metadata",
  "generatedAt": "2026-09-28T02:30:00Z",
  "source": "community",
  "metadata": [
    {
      "canonicalId": "appstream:org.mozilla.firefox",
      "summary": "Browse the web — fast, private, yours.",
      "description": "Firefox is a free and open-source web browser…",
      "screenshots": [
        {"url": "https://…/shot1.png", "caption": "Start page"}
      ],
      "permissions": {
        "sandboxing": "sandboxed",
        "capabilities": ["network", "home.read", "audio.playback"],
        "source": "curated-review"
      },
      "rating": {"mean": 4.3, "count": 128},
      "provenance": {"source": "community", "updatedAt": "2026-09-28T02:00:00Z"}
    }
  ],
  "signature": { "keyId": "…", "algorithm": "ed25519", "sig": "…" }
}
```

Rules:

- Keyed by `canonicalId` string — `CanonicalAppId.parse` strictness
  applies. Metadata for an app with no canonical id does not exist in
  v1: unresolved apps show backend data only (§3). This keeps the
  standing rule — never key community knowledge by backend id or bare
  name.
- `summary`/`description`: plain text, curator-written. Empty string =
  absent (same verbatim-not-fabricated rule as slice 2 §1: empty means
  absent, never emitted).
- `screenshots`: URL list, **https only** — a non-https URL drops that
  screenshot (diagnostic-counted, not fatal), never the record. NEVER
  embedded binaries (no base64 blobs in the doc; a mirror serving a
  2 GB doc is a DoS vector — see §2 size cap). Captions optional.
- Unknown top-level and per-record fields ignored (forward
  compatibility, same as the identity doc).
- Parse strictness lives at the record layer (`fromJson` throws
  `FormatException` on bad shape); forgiveness at the load layer
  (a bad record is skipped and counted; the rest of the doc merges).
  Same split as slices 1–3.

### 1.1 Permissions — the hard problem

What each format can honestly report today (read from the backends'
`getDetails`, not assumed):

| format | honest wire-level permission data |
|---|---|
| snap (strict) | confinement level only (`strict`/`classic`/`devmode` from the store). Interface plugs are knowable per-revision from the store API but the backend does not report them. |
| snap (classic/devmode) | confinement = full system trust. Nothing finer exists. |
| flatpak | `flatpak info --show-permissions` — live, per-install raw `key=value` pairs (`shared=network;ipc;`, `sockets=x11;wayland;`, …), rendered verbatim as labels. |
| deb / rpm / pacman | nothing — unsandboxed by design. The backends say so up front (`confinement-none`: "Unsandboxed — full system access"). |
| appimage | nothing — runs as the user, unsandboxed by default. |

**v1 decision (one paragraph):** v1 defines a small *closed*
capability vocabulary plus a three-value sandboxing level. The
community doc carries, per canonical app, **format-agnostic curated
capability claims** — what the upstream project legitimately needs,
reviewed by curators — while the *sandboxing truth* stays
**backend-reported at details time** (snap confinement from the store,
flatpak's live `--show-permissions`, deb/rpm/pacman/appimage honestly
reporting `full-system-trust` and nothing finer). For unsandboxed
formats the only honest statement is the atomic `full-system-trust`:
enumerating finer permissions for a package that can do everything
would be fabrication, so the parser *rejects* any capability list that
pairs `full-system-trust` with anything else, and rejects any finer
capabilities alongside `sandboxing: unsandboxed`. Community
permissions never enter the ADR-009 pre-install position — that list
remains the backend's live wire data, rendered before the install
button; the community block renders separately, labeled, after the
install action (§3).

Vocabulary v1 (closed; unknown ids → the *permissions block* is
dropped, the record otherwise kept — forgiveness at load, strictness
at parse):

```
full-system-trust          # atomic: unsandboxed formats ONLY, alone
network
home.read   home.write
system.read system.write
audio.playback audio.record
camera
location
usb.devices
notifications
background
```

`sandboxing`: `unsandboxed` | `sandboxed` | `unknown`.

Parser invariants (all enforced in `CommunityPermissions.fromJson`,
unit-tested):

1. `sandboxing: unsandboxed` requires `capabilities ==
   ['full-system-trust']` exactly. Anything else → block rejected.
2. `full-system-trust` alongside any other capability → block
   rejected (it is atomic).
3. `sandboxing: sandboxed` forbids `full-system-trust`.
4. `sandboxing: unknown` with an empty capability list = "curators
   haven't reviewed this app" — renders as the absent block, not as
   a claim.

Documented lossy mappings (honest, in the doc comments):

- **snap strict interfaces → vocabulary** is per-revision: the store
  can grant `network` to Firefox 136 and the community doc may
  describe 135. Community capability claims are marked
  `source: 'curated-review'` (vs `'upstream-manifest'`) so staleness
  is attributable, and the *live* backend confinement line is always
  shown alongside.
- **flatpak static manifest vs runtime overrides**: `flatpak override`
  can widen permissions after install. The community block describes
  the shipped manifest; the ADR-009 list shows the live
  `--show-permissions`. When they disagree, the live list wins for
  trust decisions — stated in the UI copy.
- **deb/rpm/pacman/appimage**: there is no mapping to be lossy —
  `full-system-trust` is the complete truth. We refuse to invent
  finer lists.

### 1.2 Ratings — read-only aggregate, submission deferred

**Decision: v1 ships a read-only aggregate; the submission protocol
is explicitly deferred.** Three reasons:

1. ADR-005 already degraded ratings in Phase 0 and forbids fake or
   placeholder scores (`null` = no data, never `0.0`-as-unknown). A
   read-only aggregate respects that: no score without evidence.
2. A submission protocol needs per-user identity, sybil resistance,
   moderation, and a write endpoint — a full slice with its own
   threat model (ballot stuffing, review brigading, key management).
   Designing it here would be scope creep wearing a trench coat.
3. Read-only still delivers the grand-vision value: community ratings
   visible on merged cards, from the same signed channel, with zero
   new trust machinery.

Schema: `"rating": {"mean": 4.3, "count": 128}`. Parse rules: `mean`
must be 0–5, `count` must be a positive int. **No mean without count
→ rating dropped** (a mean with no count is exactly the fake-score
ADR-005 forbids). The aggregate is curator-computed off-band (a
future pipeline, not this slice); the doc asserts it, the signature
authenticates the assertion, and the UI always shows the count
("4.3 · 128 community ratings"). No per-user rating data ever reaches
the client in v1 — there is nothing to game client-side beyond what
a compromised curator key can already do (§5).

## 2. Distribution: a second signed document

**Decision: new document type `identity-metadata.json` — NOT an
extension of the identity doc.** Four reasons:

1. **Size discipline.** Identity mappings are kilobytes and change
   rarely; metadata (long descriptions, screenshot lists, ratings)
   grows unboundedly and updates on its own cadence. Bundling them
   forces every identity refresh to re-fetch descriptions and every
   metadata edit to re-sign the identity doc.
2. **Hot-path separation.** The identity index loads on every search
   (merged cards need it in memory); metadata loads lazily, once per
   details page. Separate files keep `FileIdentityIndexStore.load`
   untouched and let the metadata cache live and die on its own.
3. **Reload semantics.** Independent caches, independent reload
   (`reloadIdentityIndex` vs `reloadCommunityMetadata`, §4) —
   neither clobbers the other, same shape as slice 4's preference
   store independence.
4. **One-document-per-mirror v1 discipline, kept per doc type.** Each
   mirror serves the complete metadata doc at its own URL. No
   manifest, no sharding — same rule as slice 3 §1, applied twice.

Reuse from slice 3 (deliberate, not reinvented):

- Same Ed25519 envelope, same canonical-JSON signing
  (`canonicalJsonBytes`, `verifyCommunityDoc` — gains an additive
  optional `expectedDocType` parameter; a doc whose `docType` is not
  `'community-metadata'` is rejected on the metadata path, and vice
  versa, so a mirror can't cross-serve docs).
- Same pinned trust store (`CommunityTrustStore.bootstrap` — one
  trust root signs both doc types; separate keyIds per doc type is
  future work, recorded in §6).
- Same transport seam (`CommunityIndexTransport` /
  `HttpCommunityIndexTransport`), same mirror semantics
  (comma-separated HTTPS, tried in order, first fully-verified doc
  wins), same verify-before-write + atomic temp+rename swap.
- Same no-auto-download structural rule: explicit
  `StoreHost.refreshCommunityMetadata()` only, never on a timer or
  at startup.

Two deliberate differences from the identity channel:

- **No layering.** Metadata is a single wholesale-replaced file —
  `~/.local/share/libreapp-center/identity-metadata.json`. No seed,
  no local overlay in v1 (a metadata overlay is §6 future work).
  The identity doc's seed→community→overlay layering exists because
  resolution is in the trust path for *which package gets installed*;
  metadata is display-only, so wholesale replace is sufficient and
  simpler.
- **Size cap.** The refresh loop rejects bodies over 10 MiB before
  parsing (a mirror serving a multi-GB doc must not OOM the host).
  The shared `HttpCommunityIndexTransport` is unchanged; the cap is
  enforced in the metadata refresh path where the threat is new.

Refresh gating (mirrors slice 3 §5, one flag deeper): refresh runs
only when `phase3.identity.enabled` AND `phase3.metadata.enabled`
AND `phase3.community.enabled` AND
`phase3.community.metadata.mirrors` is non-empty AND `HOME` is set.
Otherwise `CommunityMetadataRefreshResult.skipped(reason)`. All
mirrors fail → `failed(errorsByMirror)`, previous file and in-memory
cache untouched, no throw. Offline → stale metadata, no throw.

`generatedAt` is informational (staleness display), never a
freshness gate — same rule as slice 3 §1.

## 3. UI contract

Gating: everything below renders only when `phase3.metadata.enabled`
is true AND `phase3.identity.enabled` is true AND the page's app has
a non-null `canonicalId` AND `getCommunityMetadata` returned an
entry. Otherwise the details page is today's page bit-for-bit. New
`metadataEnabledProvider` in app_center follows the
`identityEnabledProvider` pattern (reads `storeFlagsProvider`).
No `backend_*` imports — UI sees `store_host`/`store_contracts`
only. New strings via `app_en.arb` keys only.

### 3.1 Merged details page sections

Order is deliberate — ADR-009 first, community second, never
interleaved:

1. **Permissions (backend, ADR-009)** — unchanged, first, from the
   selected variant's `AppDetails.permissions`. The pre-install
   trust list is always live backend data.
2. **Install button** — unchanged (`UnifiedInstallButton`).
3. **Description** — community `description` wins over the backend's
   `AppDetails.description` when present, rendered under a small
   "Community-curated" tag. The header summary stays backend data
   (identity-critical, not editorial).
4. **Screenshots** — community screenshots first (with captions),
   then backend screenshots whose URLs aren't already shown (dedup
   by URL; backend order preserved). The existing `_Screenshots`
   error/loading builders are reused — a dead community URL shows
   the same honest broken-image tile as a dead backend URL.
5. **Community permissions block** — labeled "Community-curated
   permissions", rendered AFTER the install button, never in the
   ADR-009 position. Shows the sandboxing line + capability chips.
   When the block is absent, nothing renders (no empty state).
6. **Community rating** — "4.3 · 128 community ratings", labeled by
   source. The backend `AppInfo.rating` display (ratings.ubuntu.com
   path) is unchanged; both may appear; neither overwrites the
   other. No rating without a count — ever (ADR-005).
7. License/homepage meta rows — unchanged (backend data).

### 3.2 Precedence when community and backend disagree

- **Description:** community wins (labeled). Rationale: descriptions
  are editorial; the community doc exists to curate them better
  than per-format package blurbs.
- **Screenshots:** union, community first (§3.1). Rationale: more
  screenshots is additive, not contradictory.
- **Permissions:** no merge — two blocks, backend first (§1.1: live
  wire data wins for trust decisions; the UI copy says so).
- **Rating:** side-by-side by source, no merge (different
  populations, different methods — merging means would be
  fabrication).
- **Summary/name/icon:** backend always wins. Community never
  renames the app.

### 3.3 Missing metadata — today's data, never faked

No entry, flag off, or unverified file → the page renders exactly
today's backend data. The community section is simply absent — no
"No community data yet" empty states (an empty state for missing
*curated data* reads as a placeholder; the settings page already
shows refresh state honestly). Unresolved apps (no canonical id)
never consult metadata at all.

### 3.4 Variant picker per-format display

The `_VariantSwitcher` chips keep today's content (badge + version +
size + installed check, slice 2 §5) — per-variant permission truth
stays in each variant's own ADR-009 line via `UnifiedInstallButton`.
The community capability block is format-agnostic and renders once,
under the switcher. A format with no curated data shows backend data
only — capabilities are never invented per format.

## 4. Flags (ADR-010: owner `libreapp-center`, removal `2027-06-30`)

| flag | default | meaning |
|---|---|---|
| `phase3.identity.enabled` | `false` | (exists) master identity switch — metadata keys off canonical ids, so this gates everything |
| `phase3.metadata.enabled` | `false` | master switch for community metadata: `getCommunityMetadata` returns null unless true; metadata UI never renders when false, even with a valid file on disk |
| `phase3.community.enabled` | `false` | (exists) opt-in to community distribution |
| `phase3.community.metadata.mirrors` | `''` | comma-separated HTTPS URLs for the metadata doc (same shape as `phase3.community.mirrors`); empty → no metadata fetch, ever |

Gating rules:

- `getCommunityMetadata(id)` returns null unless identity AND
  metadata flags are on. (The file may exist; the flag is the
  switch — same discipline as `resolveIdentity`.)
- `refreshCommunityMetadata()` requires identity + metadata +
  community + non-empty metadata mirrors + `HOME`. One missing →
  `skipped` with the reason.
- The metadata UI provider requires identity + metadata flags; the
  settings refresh affordance for metadata is deferred (§6) — the
  host API exists, the button doesn't (same API-first pattern as
  slice 3 → slice 4).

## 5. Threat model

Same blast-radius honesty as slice 3 §7. A community metadata doc is
*data*, never code — but unlike the identity doc, it names URLs the
client fetches, which adds one new vector.

**What a malicious metadata doc CAN do** (compromised curator key —
the only way past verification):

- **Misdescribe apps.** Wrong descriptions, misleading capability
  claims ("this app needs nothing"), fake ratings (mean+count are
  curator-asserted; the UI always shows the count so a 5.0 from 3
  ratings reads as what it is).
- **Phone home via screenshots.** A screenshot URL is a GET the
  client makes to an attacker-chosen host — a tracking pixel. This
  is the one new vector vs slice 3. Mitigations, all structural:
  images load ONLY on the explicitly-opened details page (never in
  search lists or grids), through the existing `Image.network`
  path; URLs are https-only and parse-validated; no prefetching.
  A thumbnail proxy would fix it properly — deferred as server
  work (§6), documented here.
- **UI misattribution.** Same class as slice 3's mislabeling, one
  level softer: the wrong description on the right app.

**What it CANNOT do:**

- **Escalate install privileges.** The install path is untouched;
  community data never enters `AppDetails` and never influences
  which package an install names (that's the identity index's job,
  separate doc, separate trust decision).
- **Execute code.** Descriptions/captions render as text; URLs are
  never opened automatically except image loads on the details
  page (above). No markdown rendering of community text in v1 —
  plain `Text` widgets only, so there is no link/injection surface
  to get wrong.
- **Enter the pre-install trust position.** The ADR-009 permission
  list is backend wire data, structurally separate (§1.1, §3.1).
- **Persist against the user.** Toggling `phase3.metadata.enabled`
  off or deleting `identity-metadata.json` removes all community
  metadata immediately (no local overlay to fight in v1 — §6 notes
  the correction story).

**Residual risks (accepted, documented):**

1. Compromised curator key → malicious metadata accepted until an
   app update rotates the key (same as slice 3; no in-band
   revocation in v1).
2. Stale-mirror replay: accepted by design (freshness not gated) —
   rolls metadata back, can't invent new claims.
3. Screenshot tracking pixels (§above) until a proxy exists.

## 6. Non-goals v1 (explicitly deferred, honestly)

- **Ratings submission protocol** — deferred with reasons (§1.2).
  Needs its own slice: identity, anti-sybil, moderation, write
  endpoint, and its own threat model.
- **Screenshot hosting / proxying** — URLs only, never embedded
  binaries, no thumbnail proxy (the proxy fixes the tracking-pixel
  vector; it's server work, out of scope for the client slice).
- **Local metadata overlay / user corrections** — unlike identity,
  v1 metadata has no overlay layer. Corrections today: toggle off,
  delete the file. A user-correction layer is future work.
- **Merging community data into `AppDetails`** — the trust boundary
  stays crisp: backend structs carry backend data, community structs
  carry community data, the UI composes them with labels.
- **Auto-refresh, timers, startup fetch** — explicit
  `refreshCommunityMetadata()` only (structural, like slice 3).
- **Manifest/sharding/mirror discovery** — one doc per mirror URL.
- **Per-doc-type signing keys** — one trust store signs both doc
  types in v1; `keyId` rotation is per-key as in slice 3 §3.2.
- **Metadata for unresolved apps** — no canonical id, no metadata.
- **Markdown/rich text in descriptions** — plain text only in v1.

## 7. Test matrix

No contract changes — `storeContractsVersion` stays `0.4.0` (all new
types are host-internal or additive host API; UI consumes them via
the `store_host` barrel export, same pattern as
`CommunityRefreshResult`).

Unit tests (`store_host`, fake transport implementing the fetch
seam; ephemeral Ed25519 keypairs generated in-test — never the
placeholder key; no live network):

- `verifyCommunityDoc` with `expectedDocType`: correct docType
  verifies; identity doc served on the metadata path → rejected;
  tampered metadata byte → reject; unsigned → reject; wrong key →
  reject.
- `CommunityAppMetadata.fromJson`: full record parses; unknown
  fields ignored; bad `canonicalId` → record skipped (counted);
  non-https screenshot URL → that screenshot dropped, record kept;
  `rating` without `count` → rating null, record kept; mean outside
  0–5 → rating null.
- `CommunityPermissions.fromJson` invariants (§1.1): unsandboxed +
  anything-but-`[full-system-trust]` → block rejected;
  `full-system-trust` + other capabilities → rejected; sandboxed +
  `full-system-trust` → rejected; unknown capability id → block
  dropped, record kept; empty capabilities + `unknown` sandboxing →
  absent block.
- `CommunityMetadataStore.load`: never throws (missing/corrupt →
  empty); alias-follow rule — metadata keyed by an old
  `homepage:` id is found after the identity index promotes the
  entry to `appstream:` (8-hop rule, same as `entryFor`).
- `StoreHost.refreshCommunityMetadata`: gates — any of the four
  flags off → `skipped`; metadata mirrors empty → `skipped`;
  `HOME` absent → `skipped`. Happy path: fake transport serves a
  signed doc → atomic temp+rename write observed,
  `reloadCommunityMetadata` called, result `ok` with entryCount /
  mirror / keyId. Tampered doc → mirror skipped, next tried; all
  fail → `failed`, previous file + in-memory cache untouched, no
  throw. Body > 10 MiB → rejected before parse. Offline (transport
  throws) → `failed`, stale cache intact, no throw.
- `StoreHost.getCommunityMetadata`: flag off → null even with a
  valid file on disk; unknown canonical id → null; entry present →
  returns parsed metadata.
- `StoreHost.reloadCommunityMetadata`: hand-edit the file on disk →
  reload → `getCommunityMetadata` reflects it; independent of
  `reloadIdentityIndex` (neither clobbers the other — same
  independence test shape as slice 4).

Widget tests (`app_center`, flag on, fake host):

- Merged details page with community metadata: community description
  renders with the "Community-curated" tag; backend description
  absent from the description block; screenshots render community
  first with captions, then backend extras deduped by URL, with
  loading/error states on broken URLs; community permissions block
  renders after the install button with capability chips; community
  rating shows "4.3 · 128 community ratings"; backend ADR-009
  permission list unchanged and still first.
- Precedence: backend-only description shown when community has
  none; community description labeled when it wins; header summary
  stays backend.
- Missing metadata: today's page bit-for-bit (existing tests
  unchanged — the community section is absent, no empty states).
- Variant picker: per-chip content unchanged (badge/version/size/
  installed); community block renders once under the switcher;
  selecting a variant still persists the source preference.
- Flag off: metadata file present on disk → page unchanged
  (provider returns null before touching the cache).

Gates: `melos test`, `melos analyze --fatal-infos`,
`melos format:exclude`, `scripts/dep_trace.py` zero new violations.
No new dependencies (`cryptography` is already in `store_host`;
screenshots reuse the existing image path).

## 8. Exact API surface for the implementation leaf

`store_host`, new file `lib/src/identity/community_metadata.dart`
(host-internal except the two UI-facing types, exported from
`store_host.dart` — same pattern as slice 4 §6):

```dart
// EXPORTED (UI renders these):
class CommunityAppMetadata {
  const CommunityAppMetadata({
    required this.canonicalId,   // CanonicalAppId, strict parse
    this.summary,                // String? — editorial, may be null
    this.description,            // String? — editorial, may be null
    this.screenshots = const [], // List<CommunityScreenshot>
    this.permissions,            // CommunityPermissions? — null = unreviewed
    this.rating,                 // CommunityRating? — null = no data (ADR-005)
    this.provenance = const IdentityProvenance(source: 'community'),
  });
  factory CommunityAppMetadata.fromJson(Map<String, Object?> json);
  // throws FormatException on bad shape; unknown fields ignored.
}

class CommunityMetadataRefreshResult {
  const CommunityMetadataRefreshResult.ok({
    required this.entryCount,
    required this.generatedAt,  // informational, never a freshness gate
    required this.mirror,
    required this.keyId,
  });
  const CommunityMetadataRefreshResult.skipped(this.reason);
  const CommunityMetadataRefreshResult.failed(this.errorsByMirror);
  bool get isOk; bool get isSkipped; bool get isFailed;
  // …same field shape as CommunityRefreshResult.
}

// HOST-INTERNAL (not exported):
class CommunityScreenshot {
  const CommunityScreenshot({required this.url, this.caption});
  // fromJson: non-https url → throws (caller drops the screenshot,
  // keeps the record).
}
class CommunityPermissions {
  const CommunityPermissions({
    required this.sandboxing,    // CommunitySandboxing enum
    this.capabilities = const [],// closed vocabulary, §1.1
    this.source,                 // 'upstream-manifest' | 'curated-review'
  });
  // fromJson enforces the §1.1 invariants; throws FormatException
  // when violated (caller drops the block, keeps the record).
}
enum CommunitySandboxing { unsandboxed, sandboxed, unknown }
class CommunityRating {
  const CommunityRating({required this.mean, required this.count});
  // fromJson: mean outside 0–5 or count < 1 → throws (caller drops
  // the rating, keeps the record). No mean without count, ever.
}
class CommunityMetadataStore {
  // Loads the single wholesale metadata file. Never throws for I/O
  // or JSON problems (missing/corrupt → empty map). Keyed by
  // canonical-id string; lookup follows the identity index's alias
  // chain (8-hop rule) so promoted ids still find their metadata.
  Future<Map<String, CommunityAppMetadata>> load({required List<String> paths});
}
```

`StoreHost` additions (all additive, all flag-gated):

```dart
/// Community metadata lookup (phase3-slice5.md). Null unless
/// `phase3.identity.enabled` AND `phase3.metadata.enabled` AND an
/// entry exists for [id] (alias-followed). The metadata cache loads
/// lazily on first call; never throws (worst case: null).
Future<CommunityAppMetadata?> getCommunityMetadata(CanonicalAppId id);

/// Drops the cached metadata map (same reload shape as
/// reloadIdentityIndex / reloadSourcePreferences). Independent of
/// both. Never throws.
void reloadCommunityMetadata();

/// Fetches, verifies, and installs the community metadata doc
/// (phase3-slice5.md §2): gates → per mirror (https-only, 10 MiB
/// cap): fetch → parse JSON object → verify Ed25519 envelope with
/// expectedDocType 'community-metadata' → atomic write (temp +
/// rename) to ~/.local/share/libreapp-center/identity-metadata.json
/// → reloadCommunityMetadata() → ok. All fail → failed, previous
/// file and cache untouched. Explicit-only: never called on a timer
/// or at startup. Never throws.
Future<CommunityMetadataRefreshResult> refreshCommunityMetadata({
  CommunityIndexTransport? transport,
  CommunityTrustStore trust = CommunityTrustStore.bootstrap,
});
```

`verifyCommunityDoc` gains additive optional named parameter
`expectedDocType` (null = no docType check, preserving slice-3
callers).

`flags.dart` gains (ADR-010 comments, owner `libreapp-center`,
removal `2027-06-30`):

```dart
'phase3.metadata.enabled': false,
'phase3.community.metadata.mirrors': '',
```

`app_center` additions:

- `metadataEnabledProvider` (follows `identityEnabledProvider`):
  true only when both `phase3.identity.enabled` and
  `phase3.metadata.enabled` are on.
- Details page: community sections per §3.1–§3.4. New `app_en.arb`
  keys only (e.g. `communityMetadataSectionLabel`,
  `communityMetadataCuratedTag`, `communityMetadataPermissionsLabel`,
  `communityMetadataRatingsLabel`).
- No settings-page changes in this slice (refresh affordance
  deferred — API exists, button doesn't).

What the leaf must NOT do: touch `store_contracts` (version stays
`0.4.0`); merge community data into `AppDetails`; render community
permissions in the ADR-009 position; invent capabilities for
unsandboxed formats; display unverified metadata (only the
post-verification file is ever read); auto-fetch anywhere.
