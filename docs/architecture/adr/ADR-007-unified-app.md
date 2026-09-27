# ADR-007: `UnifiedApp` — one app, one card

Date: 2026-09-26
Status: Accepted

## Context

The same app exists as snap, deb, and Flatpak. Showing three "VLC" cards is
the API-shaped answer. The reinvent answer is one card — but merging wrongly
(installing the wrong VLC) is worse than not merging at all.

## Decision

- The host merges per-format `AppInfo` into one `UnifiedApp` with a
  **format picker**. The format is a detail, like a download mirror.
- Ranking is deterministic and explainable: installed first → exact name
  match → rating → backend preference (`catalog.backend_order` flag).
  No black-box ranking in v1.
- **Dedup policy: prefer duplicate cards over an unsafe wrong merge.**
  Merge only on high-confidence identity (AppStream ID match or verified
  mapping). When unsure, show two cards honestly.

## Rationale

"Which package format should I use?" is a bug — but user trust dies the
first time a merge installs the wrong thing. Correctness outranks elegance.

## Consequences

- The dedup pipeline is host logic, tested with fixture corpora of
  known-tricky apps (same name, different upstreams).
- "Partial results" badge when a backend is down: the card shows what we
  know, honestly.

## Revisit when

The community index (Phase 3) gives stronger cross-format identity signals.
