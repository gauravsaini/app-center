# backend_deb

The deb backend: implements `store_contracts` over PackageKit (D-Bus).

## How it works

- `RealPackageKitTransport` (`lib/src/packagekit_transport.dart`) talks
  to the `org.freedesktop.PackageKit` system-bus daemon via
  `package:packagekit`. Everything PackageKit-shaped goes through the
  `PackageKitTransport` abstraction (`lib/src/transport.dart`).
- Mutating calls run on a dedicated PackageKit transaction:
  `installPackages` / `removePackages` / `updatePackages`. The
  transaction's progress events stream into `DebOperationHandle`, which
  maps them onto the operation-state DAG:
  - `download*` → `Downloading` (PackageKit's 0..100 percent, normalized
    onto a 0..100 byte scale — monotonic, bounded, never fabricated)
  - `install`/`remove`/`update` → `Applying`
  - `signatureCheck` → `Verifying`
  - anything else in flight → `Preparing`
- Cancel = `transaction.cancel()`; the daemon's `Finished` event resolves
  the honest outcome: `Cancelled`, or `Done(cancelRequested: true)` if it
  finished first, or `Cancelled` when our cancel races a daemon failure.
- Illegal transitions are never emitted — the handle holds its phase.
- Idempotent install via the installed-packages check → `Done(noop: true)`.
- Permissions surface the one honest pre-install signal debs offer
  (ADR-009): `confinement-none` — "Unsandboxed — full system access".
- `checkUpdates()` runs `GetUpdates` plus an installed-packages lookup
  to fill `fromVersion`/`toVersion`.
- Construction never touches D-Bus: the client connects lazily on first
  use, so building the transport on a PackageKit-less box is safe.
  `isAvailable()` probes via `CreateTransaction` inside the contract's
  200ms budget (a cold daemon reads as unavailable until warm).

## Testing

`package:backend_deb/testing.dart` exports `StubPackageKitTransport` —
a scripted transaction-event fake (kept out of the main barrel so
production code never depends on it). The full contract exam runs
against it: `dart test`.

## Honest v1 limits

- The real transport has **not** been exercised against a live PackageKit
  daemon — there is no system bus with PackageKit on the dev box.
- Search is `SearchNames` (name-only); description/keyword search is not
  wired yet.
- `recoverInFlight()` returns `[]`: PackageKit owns transactions
  daemon-side, but a raw transaction path cannot be reliably mapped back
  to (package, operation) — the transaction object exposes no target
  package. Crash recovery for debs needs a deliberate v2 design, not a
  guess. The exam tolerates empty.
- Polkit authentication during mutating transactions is the daemon's
  interactive flow; the backend surfaces denial as `PermissionException`
  but does not pre-flight auth.
- Non-download phases report indeterminate progress; no fabricated
  percentages. Download progress is percent-normalized, not real bytes.
