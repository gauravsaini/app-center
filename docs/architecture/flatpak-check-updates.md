# flatpak.checkUpdates — mechanism note

Parent: [updates-strangle.md](updates-strangle.md), [host-wiring.md](host-wiring.md).
Fills the last honest gap from updates-strangle: `backend_flatpak.checkUpdates()`
was stubbed to `[]`, so update-all covered snap+deb only.

## Mechanism

`flatpak update` has no machine-readable dry-run, so update discovery uses
`flatpak remote-ls --updates` — the CLI's own "which refs have a newer
version" query — scoped to the backend's configured remote (default
`flathub`):

```
flatpak remote-ls --updates --app --columns=application,name,version <remote>
```

`--app` keeps runtimes out of the updates surface (v1: the store shows app
updates; runtime updates still apply via explicit `update()` calls).
Two CLI round-trips, no N+1:

1. `flatpak list --app --columns=application,name,version` → installed-version
   map (`UpdateInfo.fromVersion`).
2. `remote-ls --updates …` → rows with a newer version available
   (`UpdateInfo.toVersion`).

Both outputs share the `application,name,version` tab-separated layout, so
the existing heuristic row parser (`_parseInstalledLine`, reverse-DNS id
anchor, whitespace fallback) is reused for both. The CLI table layout is
not a stable API — documented as heuristic, same as search/listInstalled.

## Edge cases

- **flatpak not installed** (exit 127 / "command not found") → returns `[]`.
  A missing backend is a normal runtime condition (ADR-010); the host never
  calls an unavailable backend anyway, this is belt-and-braces.
- **Any other transport failure** (network, bad remote, …) → typed
  `StoreException` via the shared `_mapError`; the host degrades to partial
  results like it does for snap/deb.
- **Empty remote output** → `[]`. Header/garbage rows are skipped by the
  parser, never fatal.
- **Update for an app not installed locally** → `fromVersion` is null;
  never a crash.
- **Multiple remotes**: only the backend's configured `remote` is queried.
  Users with extra remotes won't see those updates in v1 — future additive
  work (enumerate `flatpak remotes`, fan out).
- **`sizeBytes`** is left null: `remote-ls` reports download sizes as
  human strings ("1.2 MB"), not bytes; parsing them adds fragility for
  no v1 consumer.
