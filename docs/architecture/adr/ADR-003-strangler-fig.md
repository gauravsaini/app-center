# ADR-003: Strangler-fig migration, not a rewrite

Date: 2026-09-26
Status: Accepted

## Context

We fork `ubuntu/app-center` at `d402afd5`. Upstream keeps moving; a big-bang
rewrite would stall for months and rot against upstream history.

## Decision

Strangler fig: carve the plugin seam incrementally behind the existing UI.
New code goes in new packages; old snapd/deb paths get strangled over time.
Keep the diff reviewable; rebase regularly. The Brave model.

## Rationale

- Rewrites stall. Every incremental step ships and is testable.
- Upstream's improvements flow to us for free as long as the delta is small.
- Rebase burden is a measured CI gate (ADR-011) — the model stays honest.

## Consequences

- No flag-day. The app works at every commit.
- Discipline required: no new backend logic outside `backend_*`, ever.

## Fork position

The fork is a vehicle for the format-neutral thesis, not an identity. If
upstream adopts the direction and the fork shrinks to branding + defaults,
that counts as **success**, not failure.
