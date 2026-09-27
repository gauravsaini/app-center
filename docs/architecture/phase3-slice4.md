# Phase 3 slice 4 — identity index + preference reload polish

Leaf-scoped notes for the Phase 3 slice 4 work. Each leaf owns its
section; the coordinator assembles the merge.

## Preference reload contract (Leaf B)

`SourcePreferenceStore` (phase3-slice2.md §4) loaded once per host
lifetime in slice 2 — an honest gap (slice 2 §4: "no reload API").
Slice 4 closes it with the same reload shape slice 3 gave the
identity index (phase3-slice3.md §6).

### API

- `void StoreHost.reloadSourcePreferences()` — drops the cached
  preference map. The next preference read (`getPreferredSource` /
  any merge) rebuilds the store from disk. Never throws: worst case
  the next load yields empty preferences (`load` never throws).
- `Future<String?> StoreHost.getPreferredSource(CanonicalAppId id)` —
  the remembered backend id, or null. Reads the in-memory cache.
- `Future<void> StoreHost.setPreferredSource(CanonicalAppId id, String
  backendId)` — unchanged signature; now documented write-through.

### Semantics

- **Reload contract (same shape as `reloadIdentityIndex`):** the swap
  replaces the immutable `SourcePreferenceStore` reference, so
  in-flight merges finish on the old store — no tearing, no locks.
- **`setPreferredSource` is write-through AND in-memory atomic:** the
  in-memory map updates *before* the disk write, so set → immediate
  read-back is consistent without calling `reloadSourcePreferences`.
  If the disk write throws `StateError` (unrecoverable I/O only —
  disk full, permission denied), the in-memory value still stands:
  the current process stays consistent; the next process start
  re-reads from disk.
- **Independent caches:** `reloadSourcePreferences` touches only the
  preference store; `reloadIdentityIndex` touches only the identity
  index. Neither clobbers the other.
- **File forgiveness lives at the load layer** (as in slice 3):
  missing / unreadable / unparseable / non-map JSON → empty
  preferences, never a throw. `setPreferred` throws `StateError`
  (with the path in the message) only on unrecoverable I/O.

### Runtime identity toggle (verified in code, pinned by test)

`search()` and `installedDetailed()` read `phase3.identity.enabled`
**at call time** (per call, never cached). Resolution itself happens
per call inside `_mergeByIdentity` → `resolveIdentity` — merged
results are never cached across calls. So flipping the flag
false→true→false at runtime takes effect on the very next call, no
restart and no host-side invalidation needed:

- flag off → `search()` emits one card per backend result
  (`canonicalId == null`), exactly the v1 grouping;
- flag on → the next `search()` buffers, resolves, and merges into
  one canonical card;
- flag back off → the next `search()` is unmerged again.

The cached identity index/resolver (if already built) stays in
memory across the flip — harmless: `resolveIdentity` returns null
before touching the cache when the flag is off, and reuse of the
cache when the flag comes back on is correct (no per-flag state in
it). No UI-side invalidation is required for the toggle; the only
thing the UI must NOT do is cache merged `UnifiedApp` lists itself
across the toggle.
