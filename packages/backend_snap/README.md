# backend_snap

The snap backend: implements `store_contracts` over the snapd change API.

## How it works

- `PackageSnapdTransport` (`lib/src/snapd_transport.dart`) talks to snapd
  over `/run/snapd.socket` via `package:snapd`. Everything snapd-shaped
  goes through the `SnapdTransport` abstraction (`lib/src/transport.dart`).
- Install/remove/refresh return a **change id**; `SnapOperationHandle`
  polls `/v2/changes/{id}` and maps snapd task kinds onto operation states:
  - `download-snap` → `Downloading` (real byte progress from the task)
  - `validate-snap` → `Verifying`
  - `mount/link/setup/connect/start-snap` → `Applying`
  - anything else in flight → `Preparing`
- Cancel = `abortChange` + honest resolution: `Cancelled`, or
  `Done(cancelRequested: true)` if snapd finished first.
- `recoverInFlight()` re-attaches to snapd's own in-progress changes —
  snapd is the source of truth for crash recovery, and handles start at
  `Restoring` per the contract.
- Permissions surface the snap's **confinement** pre-install
  (`strict` / `classic` / `devmode`) — the one permission signal snaps
  honestly offer before install.
- Classic-confinement snaps install with the `classic` flag, derived from
  store metadata. User confirmation for that elevation is the UI's job.

## Testing

`package:backend_snap/testing.dart` exports `StubSnapdTransport` — a
scripted change-API fake (kept out of the main barrel so production code
never depends on it). The full contract exam runs against it:
`dart test`.

## Honest v1 limits

- The real transport has **not** been exercised against a live snapd —
  there is no snapd on the dev box. The change-polling logic is covered
  by the stub, but live-daemon quirks (auth, polkit, slow stores) are not.
- Search cancellation is best-effort: snapd `find` is one HTTP round-trip,
  so cancelling the subscription abandons the result rather than stopping
  server work.
- Post-install interface connections (`snap connections`) are not surfaced
  as permissions yet — only confinement.
- Progress for non-download phases (validating, linking) is indeterminate;
  no fabricated percentages.
- `checkUpdates()` uses `find(select=refresh)` with no caching/staggering.
