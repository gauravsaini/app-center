# Phase 3 Slice 2 — Signal Harvesting + Merged-Card UI + Format Picker

Companion to `phase3-identity-hld.md` / `phase3-identity-lld.md`. Slice 1
built the identity foundation (CanonicalAppId, IdentityIndex,
IdentityResolver, `StoreHost.resolveIdentity`, seed, flag). This slice
wires it into the product. HLD §6 merge policy is implemented as defined
there — not redesigned here. This note covers only what was genuinely
undecided: the signal seam, the exam assertion, the format-picker UI
contract, and the source-preference store.

Research basis: `/tmp/phase3-slice2-research.md` (all signals below come
from data already in hand in existing flows — zero new daemon/CLI calls).

## 1. Signal seam: `AppInfo.identitySignal`

`resolveIdentity(AppIdentity, [IdentitySignal?])` has zero callers today
and no backend exposes signals. Two candidate seams were considered:

- (a) additive `StoreBackend.identitySignal(AppIdentity)` — rejected:
  backends don't cache transport data per identity, so serving it would
  need either a cache or a re-fetch (a new daemon call in disguise).
- (b) **harvest at `AppInfo` construction** — chosen: the backend has the
  transport data in hand exactly when it builds the `AppInfo`. Signals
  ride with the data. No new calls, no caches, no lifetime questions.

Contract change (additive, `store_contracts`):

```dart
class AppInfo {
  const AppInfo({
    ...
    this.identitySignal,   // NEW: nullable, default null
  });

  /// Identity signals harvested from data the backend already had when
  /// building this AppInfo. Null = backend reports nothing.
  /// Never fabricated: only wire-level values, verbatim.
  final IdentitySignal? identitySignal;
}
```

Follow `version.dart`'s documented rule for the bump (additive member →
minor bump, same as 0.2.0→0.3.0 for `identityLookupKey`).

Per-backend harvest table (all from existing flows):

| backend | appstreamId | homepageUrl | plumbing |
|---|---|---|---|
| snap | first non-empty of `Snap.commonIds` | `Snap.website` | add fields to `SnapSummaryData`; set in `_toData` (covers find/getDetails/installed/updates) |
| deb | — (none on the wire) | `Details` dict `url` | parse in `_detailsEvents`; add to `DebPackageData`; also populate `AppDetails.homepage` (parity with rpm/pacman) |
| flatpak | `nativeId` verbatim (it IS the AppStream ID) | `fields['Homepage']` | set at `AppInfo` construction in `getDetails` (+ search path if it builds AppInfo — check) |
| rpm | — | existing `homepage` | `identitySignal: IdentitySignal(homepageUrl: p.homepage)` at `AppInfo` construction |
| pacman | — | existing `url` | same as rpm |
| appimage | — | — | skip: no verified hashes, no sanctioned homepage key (HLD §5) |

Rules:

- **First-commonId rule**: `Snap.commonIds` is a list; `IdentitySignal`
  takes one. Backends pass the first non-empty entry. Documented here,
  not guessed per call site.
- **Verbatim, never fabricated**: empty string → treated as absent
  (signal field null). The exam asserts this (§2).
- `AppDetails.homepage`: snap/deb/flatpak populate it in `getDetails`
  where the data is in hand (consistency with rpm/pacman; the details
  page can show it). Not required for resolution — the host reads
  `AppInfo.identitySignal`.

## 2. Exam assertion (LLD §3: "the exam gains an assertion in the signal-harvesting slice")

New check in `runContractExam`, following the existing check pattern:

- For every `AppInfo` returned by the backend's search/listInstalled
  fixtures: if `identitySignal != null`, every non-null field is
  non-empty (no `''` signals — empty means absent, §1).
- Backend `exam_test.dart` stubs must include signal data for at least
  one fixture app per backend that harvests (snap/deb/flatpak/rpm/
  pacman), so the path is exercised, not just the null default.
- appimage keeps `identitySignal: null` — the exam asserts the null
  default is legal (skip, don't fake).

## 3. Host: merge by canonical id

`UnifiedApp` gains additive `canonicalId` (`CanonicalAppId?`, default
null). `groupId` for a merged group is the canonical id string;
unresolved groups keep today's `${backendId}:${nativeId}`.

In `StoreHost.search` and `installedDetailed`, when
`phase3.identity.enabled` is true:

```
for each AppInfo app:
  id = await resolveIdentity(app.identity, app.identitySignal)
  key = id?.toString() ?? '${app.identity.backendId}:${app.identity.nativeId}'
  group[key].add(app)
```

Variant ordering inside a merged group — HLD §6, implemented verbatim:

1. **Installed source wins**: variants with `installedVersion != null`
   first (ties → continue down the list).
2. **User preference**: per-app remembered backend choice (§4).
3. **Flag order**: `catalog.backend_order` (extend to all six backends).
4. **First available**: registration order.

`preferred` (`variants.first`) is unchanged — the picker works by
reordering, not by special-casing the button.

Flag off, or every app unresolved → grouping is bit-for-bit today's v1
(one `UnifiedApp` per `AppInfo`).

## 4. Source-preference store (HLD §6 rule 2: "per-app remembered choice")

New host-internal `SourcePreferenceStore` (`store_host`, dart:io —
same shape as `FileIdentityIndexStore`):

- File: `~/.local/share/libreapp-center/source-preferences.json`
  (`Platform.environment['HOME']`, fallback: in-memory only).
- Shape: `{canonicalIdString: backendId}`. Load never throws (corrupt/
  missing → empty); save throws only on unrecoverable I/O as
  `StateError` (same contract as the identity store).
- Additive `StoreHost.setPreferredSource(CanonicalAppId id,
  String backendId)`; unknown backend ids are stored verbatim and
  ignored at ordering time (never throw on user data).
- Not exported from `store_host.dart` (host-internal plumbing, like the
  seed and file store).

## 5. Format-picker UI contract

Gating: everything below happens only when `phase3.identity.enabled`
is true AND `app.canonicalId != null`. Otherwise the UI is exactly
today's. New `identityEnabledProvider` in app_center reads
`storeFlagsProvider` (follows the `backendEnabledProvider` pattern).

**Details page** (`unified_details_page.dart`): extend the existing
private `_VariantSwitcher` (it was built for this future):

- One `ChoiceChip` per variant, in host order.
- Per chip: source badge (reuse `_BackendBadge`), version
  (`variant.version ?? '—'`), size (`installSizeBytes`, humanized, or
  omitted when null — never fabricated), installed check icon when
  `variant.isInstalled`.
- Selecting a chip calls `storeHost.setPreferredSource(canonicalId,
  variant.identity.backendId)` and invalidates the app provider so the
  host reorders → `preferred` becomes the pick. The install button is
  untouched (it already acts on `preferred`).
- New `app_en.arb` keys only; no new user-visible strings beyond the
  picker labels.

**Grid card** (`app_card.dart`): keep rendering `preferred` exactly as
today; add a compact affordance only when `variants.length > 1` — a
small "N formats" chip (localized) that navigates to the details page.
No picker on the card itself (picker lives where there's room to show
version/size/state: the details page).

**Install/update/remove** on merged cards target the resolved
`preferred` variant's identity — no change to the operation path.

## 6. Test matrix (slice 2)

- contracts: `AppInfo.identitySignal` defaults null; parse/round-trip
  unaffected; version bump reflected.
- exam: new signal well-formedness check passes against stub
  transports with signal data (all six backends' `exam_test.dart`).
- backends: snap/deb/flatpak harvest from fixture wire data
  (website/commonIds, `url` dict entry, `Homepage` line + nativeId);
  rpm/pacman pass through existing homepage; appimage null.
- host: firefox as snap+deb+flatpak+rpm+pacman (fixture identities +
  harvested signals, seed index) → ONE `UnifiedApp` with
  `canonicalId == appstream:org.mozilla.firefox`; ordering: installed
  source first; `setPreferredSource` reorders; unknown app →
  unmerged, `canonicalId == null`.
- UI (widget tests, flag on): merged card shows formats chip;
  details picker lists all variants with version/installed state;
  picking a variant persists preference and reorders; flag off →
  today's UI bit-for-bit (existing tests unchanged).

## 7. Explicitly not in this slice

- Community download / signatures / mirroring.
- AppStream catalog harvesting (harvested data enters as signals only,
  per HLD §4.4 — future slice).
- appimage hash catalog entries (no hashes hand-verified).
- Fuzzy matching. Ever.
