# Phase 3 Identity — LLD

Companion to `phase3-identity-hld.md`. This document is the implementation
contract: file layout, exact type shapes, algorithms, and test matrices.
Code that contradicts this document is wrong; the document changes first.

## 1. File layout

```
packages/store_contracts/lib/src/canonical_identity.dart   # NEW: types + IdentityIndex (pure Dart, no dart:io)
packages/store_contracts/lib/src/backend.dart              # ADD: identityLookupKey (defaulted)
packages/store_contracts/lib/src/version.dart              # BUMP: 0.2.0 -> 0.3.0
packages/store_contracts/lib/store_contracts.dart          # ADD: export canonical_identity.dart
packages/store_contracts/test/canonical_identity_test.dart # NEW

packages/store_host/lib/src/identity/seed_index.dart       # NEW: const seed JSON (bundled layer)
packages/store_host/lib/src/identity/file_identity_index.dart  # NEW: FileIdentityIndexStore (dart:io)
packages/store_host/lib/src/identity/identity_resolver.dart    # NEW: IdentityResolver
packages/store_host/lib/src/host.dart                      # ADD: resolveIdentity()
packages/store_host/lib/src/flags.dart                     # ADD: phase3.identity.enabled=false
packages/store_host/lib/store_host.dart                    # ADD: export identity/
packages/store_host/test/identity_resolver_test.dart        # NEW
packages/store_host/test/file_identity_index_test.dart     # NEW

packages/backend_rpm/lib/src/backend.dart                  # ADD: identityLookupKey override
packages/backend_pacman/lib/src/backend.dart               # ADD: identityLookupKey override
packages/backend_rpm/test/identity_key_test.dart            # NEW (or extend existing)
packages/backend_pacman/test/identity_key_test.dart         # NEW (or extend existing)
```

No UI files touched. No `backend_*` imports outside backend packages
(dep_trace must stay clean).

## 2. `store_contracts`: `src/canonical_identity.dart`

### 2.1 `CanonicalAppId`

```dart
enum CanonicalIdScheme { appstream, homepage }

class CanonicalAppId {
  const CanonicalAppId(this.scheme, this.value);
  final CanonicalIdScheme scheme;
  final String value; // e.g. 'org.mozilla.firefox', 'mozilla.org/firefox'

  /// Parses 'appstream:org.mozilla.firefox'. Throws FormatException on
  /// unknown scheme, empty value, or whitespace in value.
  factory CanonicalAppId.parse(String s);

  @override String toString(); // 'appstream:org.mozilla.firefox'
  // == / hashCode on (scheme, value). No normalization of value:
  // the index stores canonical forms; parse is strict.
}
```

Strictness is deliberate: silent normalization at parse time hides data
bugs. Normalization happens once, at index-build time (`normalizeHomepage`).

### 2.2 `IdentitySignal`

```dart
class IdentitySignal {
  const IdentitySignal({this.appstreamId, this.homepageUrl});
  final String? appstreamId;   // raw; matched verbatim against entry appstreamIds
  final String? homepageUrl;   // raw; normalized before matching
}
```

Both nullable: backends report what they have. Slice 1: no backend
reports signals yet (slice 2); the resolver accepts them and tests cover
the paths with fixtures.

### 2.3 `CanonicalEntry`

```dart
class CanonicalEntry {
  const CanonicalEntry({
    required this.id,
    this.displayName,
    this.appstreamIds = const [],
    this.homepages = const [],       // stored NORMALIZED
    this.backendKeys = const {},     // backendId -> lookup keys
    this.provenance = const IdentityProvenance(source: 'unknown'),
  });
  final CanonicalAppId id;
  final String? displayName;
  final List<String> appstreamIds;
  final List<String> homepages;
  final Map<String, List<String>> backendKeys;
  final IdentityProvenance provenance;

  Map<String, Object?> toJson();           // canonical key order (§4)
  factory CanonicalEntry.fromJson(Map<String, Object?> json); // throws FormatException on bad shape
}

class IdentityProvenance {
  const IdentityProvenance({required this.source, this.updatedAt});
  final String source;      // 'seed' | 'local' | 'community' | ...
  final DateTime? updatedAt;
}
```

`fromJson` is strict per-entry (bad entry → FormatException); the *store*
decides whether to skip bad entries (§6) — strictness lives at the parse
layer, forgiveness at the load layer.

### 2.4 `normalizeHomepage`

```dart
/// Total function: never throws. Garbage in -> stable garbage key.
String normalizeHomepage(String url);
```

Algorithm: trim → strip scheme (`^[a-zA-Z][a-zA-Z0-9+.-]*://`) → cut at
first `?`/`#` → split host/path at first `/` → host lowercase, strip one
leading `www.` → strip trailing `/` from path → if path empty, return
host; else `host/path`. No URL-decoding (encoded forms are distinct keys;
curated data uses plain forms).

### 2.5 `IdentityIndex`

Pure in-memory index built from JSON docs. No I/O.

```dart
class IdentityIndex {
  IdentityIndex._(...);

  /// Builds from layered docs, lowest priority FIRST.
  /// Later docs override per §2.6. Malformed docs are SKIPPED
  /// (a corrupt index must never crash the store); [skippedDocs]
  /// counts them for diagnostics.
  factory IdentityIndex.fromJsonDocs(List<Map<String, Object?>> docs);
  factory IdentityIndex.empty();

  int get skippedDocs;
  int get entryCount;

  /// Resolution order (§2.7): backend-key -> appstream signal ->
  /// homepage signal -> null (unresolved).
  CanonicalAppId? resolve(String backendId, String lookupKey,
      [IdentitySignal? signals]);

  /// Follows aliases. Null when unknown.
  CanonicalEntry? entryFor(CanonicalAppId id);

  /// Canonical JSON (§4). Round-trips through fromJsonDocs.
  Map<String, Object?> toJson();
}
```

Internal maps (all keyed by exact string):

- `_byBackendKey`: `'$backendId:$lookupKey'` → canonical string
- `_byAppstream`: appstreamId → canonical string
- `_byHomepage`: normalized homepage → canonical string
- `_entries`: canonical string → CanonicalEntry
- `_aliases`: canonical string → canonical string

### 2.6 Layered merge

Docs processed in order (lowest priority first). Per doc:

- `schemaVersion`: must be `1`; other versions → whole doc skipped
  (counted in `skippedDocs`). Forward-compat gate.
- `entries`: list of entry objects. Keyed by `canonicalId` string.
  - New canonicalId → insert.
  - Existing → **replace** scalar fields (`displayName`, `provenance`),
    **union** signal lists (`appstreamIds`, `homepages`, and per-backend
    key lists — deduped, order-preserving with existing first).
- `aliases`: map string→string; union, later doc wins on key conflict.
- Unknown top-level fields ignored (forward compatibility).

Rationale for union-vs-replace: signals accumulate across curators;
display/provenance is editorial and belongs to the highest layer.

### 2.7 Resolution algorithm

```
resolve(backendId, lookupKey, signals):
  1. k = '$backendId:$lookupKey'
     if k in _byBackendKey: return parse(_byBackendKey[k])      # curated
  2. if signals?.appstreamId != null and in _byAppstream:
       return parse(...)                                          # appstream signal
  3. if signals?.homepageUrl != null:
       h = normalizeHomepage(signals.homepageUrl)
       if h in _byHomepage: return parse(...)                    # homepage signal
  4. return null                                                 # unresolved
```

Deterministic; total (never throws on well-formed index); O(1) per step.
Empty lookupKey → skips step 1 (no empty-key entries exist; index build
drops empty keys).

### 2.8 Alias following

`entryFor(id)`: `s = id.toString()`; loop `s = _aliases[s] ?? break`
(max 8 hops, then null — cycle guard); return `_entries[s]`. Aliases let
`homepage:mozilla.org/firefox` resolve to the entry after it is promoted
to `appstream:org.mozilla.firefox`.

## 3. `StoreBackend.identityLookupKey` (additive)

```dart
/// Key used for cross-format identity resolution
/// (docs/architecture/phase3-identity-hld.md §5).
///
/// This is NOT the card key: identity is arch- and version-agnostic.
/// rpm's card key is `name.arch`; its identity key is `name`.
/// The default returns [identity.nativeId]; backends whose nativeId
/// embeds version/arch/state MUST override.
/// Never throws, never returns empty for a valid [identity].
String identityLookupKey(AppIdentity identity) => identity.nativeId;
```

- Contract bump: `storeContractsVersion` 0.2.0 → **0.3.0**
  (additive method with default — version.dart's own rule). Majors
  untouched; all backends declare `contractVersion => storeContractsMajor`.
- **rpm** override: `RpmPackageId.parse(identity.nativeId).name`
  (parse never throws on backend-issued ids; defensive: on parse failure
  return nativeId — total function).
- **pacman** override: name token (same helper as cardKeyFor).
- Exam: no change in slice 1 (default is trivially total; overrides are
  unit-tested in backend packages). The exam gains an assertion in the
  signal-harvesting slice when backends start reporting signals.

## 4. JSON canonical form

`toJson()` emits keys in this exact order (diffability):
`schemaVersion, generatedAt, source, entries[], aliases{}`. Entry order:
`canonicalId, displayName?, appstreamIds[], homepages[], backends{},
provenance{source, updatedAt?}`. `generatedAt`/`updatedAt`: UTC ISO-8601
with `Z`. Lists sorted where semantics allow (appstreamIds, homepages,
backend key lists sorted; `entries` sorted by canonicalId; `aliases`
keys sorted). `displayName` omitted when null (not null-valued).

## 5. `store_host`: `src/identity/`

### 5.1 `seed_index.dart`

```dart
/// Bundled identity seed (layer 1). Hand-curated; incomplete by design.
/// See docs/architecture/phase3-identity-hld.md §4.4.
const String kIdentitySeedJson = '''{...}''';
```

~18 entries (HLD appendix A). Raw string constant — no asset pipeline in
a pure-Dart package; the JSON is the source of truth, the constant is the
vehicle.

### 5.2 `file_identity_index.dart`

```dart
class FileIdentityIndexStore {
  /// Loads the layered index: seedJson, then each of [overlayPaths]
  /// that exists and parses (missing/unparseable files skipped).
  /// Never throws for I/O or JSON problems: worst case returns the
  /// seed-only index (possibly empty).
  Future<IdentityIndex> load({required String seedJson, List<String> overlayPaths = const []});

  /// Writes [entries] as a single overlay doc {schemaVersion:1,
  /// source:'local', entries:[...]} to [path], creating parent dirs.
  /// Throws only on unrecoverable I/O (disk full, permission) as
  /// StateError with the path in the message.
  Future<void> saveOverlay(String path, List<CanonicalEntry> entries);
}
```

No caching in slice 1 (load is cheap: one small JSON parse). No file
watching (slice: community download).

### 5.3 `identity_resolver.dart`

```dart
class IdentityResolver {
  IdentityResolver({required IdentityIndex index, required Map<String, StoreBackend> backends});
  final IdentityIndex index;
  final Map<String, StoreBackend> backends; // backendId -> backend

  /// Resolves [id] to a canonical id, or null when unresolved.
  /// Unknown backendId -> null (never throws).
  CanonicalAppId? resolve(AppIdentity id, [IdentitySignal? signals]) {
    final backend = backends[id.backendId];
    if (backend == null) return null;
    return index.resolve(id.backendId, backend.identityLookupKey(id), signals);
  }

  CanonicalEntry? entryFor(CanonicalAppId canonicalId) => index.entryFor(canonicalId);
}
```

### 5.4 `StoreHost.resolveIdentity`

```dart
/// Phase 3 identity resolution (phase3-identity-hld.md).
/// Returns null unless `phase3.identity.enabled` AND the index resolves
/// the identity. Null = unresolved = today's per-backend behavior.
/// The index loads lazily on first call and is cached for the host's
/// lifetime (slice 1: no reload API).
Future<CanonicalAppId?> resolveIdentity(AppIdentity id, [IdentitySignal? signals]);
```

Lazy `_identityIndex`/`_identityResolver` fields, built from
`FileIdentityIndexStore().load(seedJson: kIdentitySeedJson)` with the
overlay path from a new flag? Slice 1: overlay path constant
(`~/.local/share/libreapp-center/identity-overlay.json` — resolved via
`Platform.environment['HOME']`, fallback: no overlay). No new flag for
the path in slice 1; the feature flag gates everything.

### 5.5 Flag

```dart
// Phase 3 cross-format identity (docs/architecture/phase3-identity-hld.md):
// true -> StoreHost.resolveIdentity() consults the local identity index;
// false (default) -> resolveIdentity() always returns null and the index
// is never loaded. New foundation, needs dogfooding.
// Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
'phase3.identity.enabled': false,
```

### 5.6 Exports

`store_host.dart` gains `export 'src/identity/identity_resolver.dart';`
(the resolver + result types). `CanonicalAppId` etc. come via the
`store_contracts` re-export. `FileIdentityIndexStore` and the seed are
**not** exported (host-internal plumbing).

## 6. Seed data (HLD appendix A content)

84 entries as of 2026-09-28 (18 original + 66 added in the slice-7
expansion: browsers, dev tools, media, office/productivity, comms,
graphics/photo, games, system utils). Every entry: `canonicalId`
(appstream:), `displayName`, `appstreamIds[1]`, `homepages[1]`
(normalized), `backends` keys for the backends where the mapping is
confidently known, `provenance{source: 'seed'}`. The full list lives in
`seed_index.dart` (the JSON is the source of truth); the table below
documents the original 18. rpm/pacman keys are **bare names** (arch-agnostic identity,
§3 of backend override). Backends omitted where the package does not
exist in the backend's normal sources (e.g. no deb for discord/spotify,
no pacman for vscode).

| App | appstream | homepage (normalized) | snap | deb | flatpak | rpm | pacman |
|---|---|---|---|---|---|---|---|
| Firefox | org.mozilla.firefox | mozilla.org/firefox | firefox | firefox | org.mozilla.firefox | firefox | firefox |
| Thunderbird | org.mozilla.Thunderbird | mozilla.org/thunderbird | thunderbird | thunderbird | org.mozilla.Thunderbird | thunderbird | thunderbird |
| Chromium | org.chromium.Chromium | chromium.org | chromium | chromium | org.chromium.Chromium | chromium | chromium |
| VLC | org.videolan.VLC | videolan.org/vlc | vlc | vlc | org.videolan.VLC | vlc | vlc |
| GIMP | org.gimp.GIMP | gimp.org | gimp | gimp | org.gimp.GIMP | gimp | gimp |
| Inkscape | org.inkscape.Inkscape | inkscape.org | inkscape | inkscape | org.inkscape.Inkscape | inkscape | inkscape |
| Blender | org.blender.Blender | blender.org | blender | blender | org.blender.Blender | blender | blender |
| Kdenlive | org.kde.kdenlive | kdenlive.org | kdenlive | kdenlive | org.kde.kdenlive | kdenlive | kdenlive |
| OBS Studio | com.obsproject.Studio | obsproject.com | obs-studio | obs-studio | com.obsproject.Studio | obs-studio | obs-studio |
| Audacity | org.audacityteam.Audacity | audacityteam.org | audacity | audacity | org.audacityteam.Audacity | audacity | audacity |
| Krita | org.kde.krita | krita.org | krita | krita | org.kde.krita | krita | krita |
| LibreOffice | org.libreoffice.LibreOffice | libreoffice.org | libreoffice | libreoffice | org.libreoffice.LibreOffice | libreoffice | libreoffice-fresh |
| VS Code | com.visualstudio.code | code.visualstudio.com | code | code | com.visualstudio.code | code | — |
| Telegram | org.telegram.desktop | telegram.org | telegram-desktop | telegram-desktop | org.telegram.desktop | telegram-desktop | telegram-desktop |
| Discord | com.discordapp.Discord | discord.com | discord | — | com.discordapp.Discord | — | discord |
| Spotify | com.spotify.Client | spotify.com | spotify | — | com.spotify.Client | — | — |
| Steam | com.valvesoftware.Steam | store.steampowered.com | steam | steam | com.valvesoftware.Steam | — | steam |
| KeePassXC | org.keepassxc.KeePassXC | keepassxc.org | keepassxc | keepassxc | org.keepassxc.KeePassXC | keepassxc | keepassxc |

No appimage keys in the seed: no hashes are hand-verified; the mechanism
(exact-hash curated entries) exists, entries are empty by honesty.

## 7. Test matrix

### `store_contracts/test/canonical_identity_test.dart`

- `CanonicalAppId.parse`: valid both schemes; rejects unknown scheme /
  empty value / whitespace / missing colon → FormatException.
- `==`/`hashCode`/`toString` round-trip.
- `normalizeHomepage`: the doc examples + `HTTP://WWW.Example.COM/A/` →
  `example.com/A`; garbage (`'not a url'`) → stable non-throwing key;
  empty → `''`.
- Index from hand-written docs:
  - backend-key hit (firefox deb) → `appstream:org.mozilla.firefox`.
  - appstream signal hit (no backend key) → resolves.
  - homepage signal hit (raw URL with scheme/www) → resolves.
  - ranking: backend-key beats appstream beats homepage (one identity
    matching all three differently → backend-key wins; then drop the
    backend key → appstream wins).
  - unknown backend/key/signals → null.
  - `entryFor` follows aliases; cycle guard terminates.
  - layered merge: overlay replaces displayName, unions appstreamIds,
    adds backend keys; bad doc (schemaVersion 2, malformed entry) →
    skipped, counted, rest loads.
  - `toJson` → `fromJsonDocs` round-trip preserves resolution.

### `store_host/test/identity_resolver_test.dart`

- Seed-loaded index (real `kIdentitySeedJson`): firefox as
  snap/deb/flatpak/rpm/pacman identities → **one** canonical id.
  (rpm/pacman identities use realistic version-pinned nativeIds to prove
  the lookup-key normalization.)
- Unknown app (`snap:some-obscure-tool`) → null.
- Unknown backend id → null (never throws).
- Signal-only resolution: backend key absent, appstream signal present →
  resolves (fixture-constructed index, not the seed).

### `store_host/test/file_identity_index_test.dart`

- Temp dir: write overlay JSON with one new entry + one override;
  `load` merges over seed; resolution reflects both.
- Missing overlay path → seed-only index, no throw.
- Corrupt overlay file → skipped, seed still loads.
- `saveOverlay` round-trip: save → load → entry present.

### backend rpm/pacman

- `identityLookupKey(AppIdentity(backendId:'rpm', nativeId:
  'firefox;136.0-1.fc42;x86_64;updates;installed'))` → `'firefox'`.
- pacman `'firefox;146.0-1;;'` → `'firefox'`.
- Default (snap): nativeId unchanged.

### Gates

`melos test`, `melos analyze --fatal-infos`, `melos format:exclude`
(all green); `scripts/dep_trace.py` zero new violations; contract
version bump reflected in version.dart only.

## 8. Explicitly deferred to slice 2+

- Per-backend signal harvesting (snap publisher, deb PackageKit `url`,
  flatpak `Homepage` parsing).
- `UnifiedApp.canonicalId` + merged-card UI + format picker + merge
  policy implementation (HLD §6).
- Community download / signatures / mirroring.
- Index reload API, file watching, `saveOverlay` callers.
- appimage hash catalog entries.
