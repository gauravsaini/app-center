# ADR-002: Plugin architecture — `store_contracts` is the law

Date: 2026-09-26
Status: Accepted

## Context

App Center today has snapd/deb logic woven through UI and services. Adding
Flatpak — then AppImage, dnf, pacman, nix — by copy-paste would multiply the
coupling until nothing can move. DeepSeek-harness lesson: *everything is a
plugin.*

## Decision

Melos packages with enforced dependency arrows:

- `store_contracts` — `StoreBackend`, `AppIdentity`/`AppInfo`/`AppDetails`,
  `OperationHandle`, `UnifiedCatalog`, `OperationEngine`, `FeatureFlags`,
  `StoreException`. Zero dependencies besides meta/freezed. Versioned SemVer.
- `store_host` — catalog, engine, flags, policy, metadata. Depends ONLY on
  `store_contracts`.
- `backend_snap`, `backend_deb`, `backend_flatpak` — implement `StoreBackend`.
- `app_center` — UI shell. Depends on `store_contracts` + `store_host` ONLY.

A CI import linter fails the build if `app_center` imports `backend_*`.
Architecture as code, not as wiki.

## Rationale

- Strangers (and future us) can write backends without reading host source.
- The UI can never grow backend tentacles again — the linter guarantees it.
- The contract exam (LLD §9, `operation-state-machine.md` §11) gates shipping.

## Consequences

- All cross-format logic lives in the host; backends are thin adapters.
- Breaking the law requires a major version bump + declared migration —
  a plugin ecosystem dies on silent breakage.

## Revisit when

Essentially never without a major version. The law is the product.
