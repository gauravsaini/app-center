# ADR-010: Backends are detected at runtime; flags have owners

Date: 2026-09-26
Status: Accepted

## Context

A backend may simply be missing — no snapd on Fedora, no Flatpak installed.
That is normal, not an application failure. We also need kill switches for
half-built backends.

## Decision

- The host probes `StoreBackend.isAvailable()` (<200ms, no side effects,
  safe to call twice). Missing backends degrade to a "partial results"
  posture — never a failure screen, never a crash.
- Every backend ships behind `backend.<id>.enabled`.
- Every flag records **owner, default, and removal date**. A flag without a
  removal date is tech debt with a name.

## Rationale

The store must feel native on every distro, and we must be able to ship
dark and kill fast. Silent degradation keeps the app honest about what it
can do *here*.

## Consequences

- The UI renders backend availability honestly (a quiet "2 of 3 sources"
  note beats a mysterious missing app).
- Flag hygiene is reviewed; expired flags are removed, not inherited.
