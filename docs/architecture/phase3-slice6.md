# Phase 3 slice 6 — metadata settings UX (design note)

Companion to `phase3-slice4.md` (the template) and `phase3-slice5.md`
(§§2,4,8: flags, host API, exact types). Covers only what was genuinely
undecided; everything else mirrors slice 4.

## 1. Placement: subsection inside the existing "App identity" section

New `YaruSection` rejected — metadata is the second half of the
identity story (mappings → curated metadata), and a separate page
would be one tile for one toggle. Chosen: a metadata subsection in
`_AppIdentitySection` after the community-identity block (Divider,
`titleSmall` headline, description, signature note, toggle, mirror
status, refresh control). Providers/state/store live in the new
`metadata_settings.dart` + `community_metadata_refresh_store.dart`
(exported via `settings.dart`), mirroring slice 4's
`identity_settings.dart` / `community_refresh_store.dart` split.

## 2. Refresh state machine: parallel, not shared

`CommunityMetadataRefreshUiState` (idle → checking → up-to-date |
failed | skipped) parallels `CommunityRefreshUiState` with its own
notifier. One generic notifier would need ~6 injected parameters to
save ~60 lines while tangling the sections' honest-copy keys;
parallel matches the host's independence discipline
(`reloadCommunityMetadata` vs `reloadIdentityIndex`). The
no-faked-progress rule stands (slice 4 §2): one host Future → one
indeterminate "checking" state.

## 3. What the metadata display shows

- Mirror status: count from `phase3.community.metadata.mirrors` +
  winning mirror from the last record (same two-line pattern as the
  identity section). No editing UI — mirrors are an operator trust
  decision (slice 4 §5).
- keyId: "Signature valid — key `<keyId>`" with slice 4's disclaimer:
  proves the doc came from the pinned curator key's holder; does NOT
  prove descriptions/screenshots/permissions/ratings correct or safe.
  Never "verified safe". No in-band revocation v1 (same as slice 3).
- Last-refresh: attempt/success timestamps + entry count, persisting
  across failed attempts — a failure never erases the last success.
- Persistence: parallel `CommunityMetadataRefreshStore`
  (`community-metadata-refresh.json`); load never throws, save
  best-effort; slice 4's store untouched.
- Toggle: `setMetadataEnabled` (top-level, like `setIdentityEnabled`)
  invalidates `metadataEnabledProvider` + the `communityMetadataProvider`
  family so details sections appear without restart;
  `setIdentityEnabled` gains the same invalidation (identity gates
  metadata).
- Test seam: `metadataTransportOverrideProvider` /
  `metadataTrustOverrideProvider` (null in production → real
  transport/bootstrap trust). `CommunityTrustStore` gets an additive
  barrel export (slice-4 §6 pattern). Tests sign ephemeral docs with
  `cryptography` (dev_dependency) + a test-local canonical-JSON
  encoder, driving the REAL host — never the placeholder key.

All new strings via `app_en.arb` keys only.
