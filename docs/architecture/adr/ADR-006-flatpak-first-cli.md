# ADR-006: Flatpak first — CLI wrapper, vertical slice behind a flag

Date: 2026-09-26
Status: Accepted

## Context

We need one backend end-to-end to prove the plugin architecture before
touching the rest. `libflatpak` FFI is the "right" API, but `flatpak_dart`
production readiness is unverified; the CLI is stable, scriptable, and its
failures are debuggable.

## Decision

- First vertical slice: **Flatpak end-to-end** behind `backend.flatpak.enabled`.
- Implementation: **CLI wrapper first** (`flatpak search/install/uninstall`,
  progress parsing). `libflatpak` FFI later, only if justified by measured
  need (latency or robustness under ADR-011 benchmarks).

## Rationale

Lower risk, faster proof. CLI output is inspectable; FFI is an optimization,
not a prerequisite. The contract exam doesn't care how the backend talks —
only that it honors the law.

## Consequences

- `backend_flatpak` spawns processes: it MUST honor the 500ms search-cancel
  rule (kill children, no orphaned `flatpak` processes).
- Progress parsing must never fabricate (see `operation-state-machine.md` §4).

## Revisit when

The CLI proves too slow or too fragile under benchmark pressure.
