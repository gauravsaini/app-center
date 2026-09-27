# ADR-008: Operations are a state machine, not a button

Date: 2026-09-26
Status: Accepted

## Context

Current UX — ours and GNOME Software's — is fire-and-poll: installs you can't
cancel (our own issue list has "deb operations cannot be cancelled"), raw
stderr as error messages, progress that lies. The install interaction is the
most-felt part of a store and the least rethought.

## Decision

Every install/update/remove is an `OperationHandle` governed by the full
contract in `operation-state-machine.md`:

- Cancellable from any state, terminal within 2s — never silently failed.
- `failed` always carries a typed `StoreException` with a structured
  `Remediation` (retry / freeSpace / fixBackend / reportBug / none) —
  the host renders actions, not strings.
- Honest progress: monotonic, never fabricated, indeterminate when unknown.
- Idempotent no-ops (`done` with `noop: true`, no re-download).
- Crash recovery via the `restoring` state.

## Rationale

This is the reinvent of the highest-touch interaction in the product.
Cancellation that works and errors that explain themselves are the moat —
not the backend count.

## Consequences

- Backends do real work mapping native errors into the taxonomy; the
  contract exam enforces it. A backend that can't explain its failures
  doesn't ship.
