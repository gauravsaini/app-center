# Architecture Decision Records

Decisions are cheap to make and expensive to forget. This directory is the
memory.

| ADR | Title | Status |
|---|---|---|
| [001](ADR-001-no-daemon-phase-0.md) | No backend daemon in Phase 0 | Accepted |
| [002](ADR-002-plugin-architecture.md) | Plugin architecture — `store_contracts` is the law | Accepted |
| [003](ADR-003-strangler-fig.md) | Strangler-fig migration, not a rewrite | Accepted |
| [004](ADR-004-deb-first-distribution.md) | Native deb-first distribution | Accepted |
| [005](ADR-005-ratings-degraded.md) | Ratings degraded in Phase 0 | Accepted |
| [006](ADR-006-flatpak-first-cli.md) | Flatpak first — CLI wrapper, vertical slice behind a flag | Accepted |
| [007](ADR-007-unified-app.md) | `UnifiedApp` — one app, one card | Accepted |
| [008](ADR-008-operation-state-machine.md) | Operations are a state machine, not a button | Accepted |
| [009](ADR-009-reinvent-dont-wrap.md) | Reinvent, don't wrap | Accepted |
| [010](ADR-010-runtime-detection-flags.md) | Backends are detected at runtime; flags have owners | Accepted |
| [011](ADR-011-benchmarks-as-gates.md) | Benchmarks are gates, not dashboards | Accepted |

Format: Context → Decision → Rationale → Consequences → Revisit when.
Superseded ADRs stay in place with status updated — history is not rewritten.
