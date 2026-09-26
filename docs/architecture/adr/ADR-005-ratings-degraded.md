# ADR-005: Ratings degraded in Phase 0

Date: 2026-09-26
Status: Accepted

## Context

`ratings.ubuntu.com` is Canonical-controlled. The client code ships in App
Center, but the review corpus and the identity/moderation path do not
transfer. The server code is reportedly public, but self-hosting means a
cold start plus an abuse problem we are not staffed to fight in Phase 0.

## Decision

Phase 0 removes or gracefully degrades ratings: no ratings UI, or an honest
"no ratings yet" empty state. Never fake or placeholder scores.

## Rationale

Shipping with Canonical's corpus is not an option; a cold-start self-host is
a Phase 3 (community index) problem, not a Phase 0 problem.

## Consequences

- `AppInfo.rating` stays nullable. `null` = no data, never `0.0`-as-unknown
  (already contracted in LLD).
- Ranking must not depend on ratings being present.

## Revisit when

The community index (grand vision Phase 3) gives us our own trust corpus.
