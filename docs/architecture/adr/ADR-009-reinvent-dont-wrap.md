# ADR-009: Reinvent, don't wrap

Date: 2026-09-26
Status: Accepted

## Context

GNOME Software proved you can call three APIs and put them in tabs. Nobody
was won over. Wrapping asks "how do I show snap results next to Flatpak
results?"; reinventing asks "what IS an app when it exists in three formats
at once?" (Course correction to `grandvision.md`, 2026-09-26.)

## Decision

We use the APIs for plumbing and **rethink everything the user touches**.
Five reinvent bets are architecture, not polish:

1. **Identity** — the store thinks in apps, not packages (ADR-007).
2. **Operations** — installs are cancellable state machines (ADR-008).
3. **Trust** — permissions shown *before* install (PolicyCenter). Trust is
   designed, not documented.
4. **Discovery** — search is the starting line; use-case-based discovery
   ("I want to edit video" → a curated stack) comes later.
5. **Metadata** — the community index (vision Phase 3) reinvents metadata
   instead of only consuming AppStream.

## Rationale

API access is table stakes; rethought primitives are the differentiator.
This thesis is what makes the fork worth doing instead of contributing
Flatpak support to GNOME Software.

## Consequences

- The test for every feature: *did we rethink it, or just wire the API to
  a button?* Wrappers don't ship.
- Individual bets can be descoped per phase; the thesis itself is not
  negotiable.

## Revisit when

Never — this is the thesis. (How each bet ships is decided per phase.)
