# ADR-011: Benchmarks are gates, not dashboards

Date: 2026-09-26
Status: Accepted

## Context

"Better" in the grand vision is a slogan unless it's a number. Nobody will
believe a faster store that can't show the measurement.

## Decision

These are gates with budgets — a regression fails the build like a test:

- **Cold-start time** — process launch to interactive store.
- **Search latency** — p95 per query, per backend and merged.
- **Install success rate** — across backends, on fixture corpora.
- **Rebase burden** — time and conflict count per upstream rebase
  (keeps the ADR-003 Brave model honest).

## Rationale

Numbers are the moat for "better". Dashboards get ignored; gates get fixed.

## Consequences

- Benchmarks run locally before push for now, on reference hardware profiles;
  GitHub CI is the last step.
- Budgets start loose and tighten as real numbers come in — but they only
  move by ADR, never by quiet edit.

## Revisit when

Budgets need recalibration, or a new dimension (memory, battery) earns a gate.
