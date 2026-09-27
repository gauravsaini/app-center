# Phase 3 Slice 3 — Community Index Distribution: Download, Signatures, Reload

Companion to `phase3-identity-hld.md` / `phase3-identity-lld.md` /
`phase3-slice2.md`. Slices 1–2 built the identity foundation, signal
harvesting, and merged-card UI. This slice builds the **distribution
layer** the grand vision's "community-owned index" needs: fetching a
community-curated index layer over the network, verifying it, merging it
as a layer, and reloading without a host restart.

HLD §4.2 sketched this as "layer 3 — community download (future slice):
signed, mirrored, owned by no one". This note implements what's
specified there and designs what's genuinely open: the signature
scheme, trust roots, mirror discovery, the update flow, the reload
contract, and the threat model.

## 1. Distribution format

The layered JSON **is** the distribution format — no translation step.
A community layer is one JSON document following the v1 schema (HLD
§4.3): `schemaVersion`, `generatedAt`, `source: 'community'`,
`entries[]`, `aliases{}`, plus the `signature` envelope the HLD
reserved:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-28T00:00:00Z",
  "source": "community",
  "entries": [ ... ],
  "aliases": { ... },
  "signature": {
    "keyId": "libreapp-index-2026-01",
    "algorithm": "ed25519",
    "sig": "<base64 of signature>"
  }
}
```

Rules:

- **One document per mirror URL.** Each mirror serves the complete
  signed doc. No manifest, no sharding in v1 — the index is thousands
  of entries, one GET is fine. A manifest/shard scheme is future work
  when (if) the index outgrows a single fetch; recorded in §8.
- **Unsigned community docs are rejected, never merged.** The community
  layer *requires* a valid signature envelope. A doc without
  `signature` is skipped exactly like a corrupt doc (counted, not
  fatal) — a signature-stripping attacker gains nothing.
- **Unknown top-level fields are ignored** by `IdentityIndex.fromJsonDocs`
  (LLD §2.6) — but verification happens *before* merge (see §3), so the
  envelope is stripped by the verifier, not silently absorbed.
- `generatedAt` is informational (staleness display); it is NOT a
  freshness gate — offline-first means a stale index is acceptable and
  a freshness gate would turn every offline boot into a failure (§5).

## 2. Signature scheme: Ed25519 over canonical JSON

### 2.1 Why Ed25519, why a new dependency

Nothing in the monorepo verifies signatures today (research: `crypto`
is hash-only, D-Bus "signatures" are type metadata, PackageKit GPG
errors are daemon-mapped, never verified in Dart). Hand-rolling Ed25519
is a classic footgun — the slice adds the well-known pure-Dart
[`cryptography`](https://pub.dev/packages/cryptography) package to
`store_host` (host-side feature, host-side dependency; no backend or
contract package gains a crypto dep).

### 2.2 What is signed

The signature covers the **canonical JSON bytes of the document with
the `signature` envelope removed**. Canonical form (new, specified
here; implemented as `canonicalJsonBytes` in `store_host`):

- Object keys sorted lexicographically (code-unit order), recursively.
- No whitespace. Separators `:` and `,`.
- Strings: JSON escaping per RFC 8259 (`\"`, `\\`, `\n`, `\uXXXX`
  for other controls). Numbers: as emitted by `jsonEncode` for
  int/double (the index schema uses strings and ints only; doubles
  are not expected — if present, `jsonEncode` form).
- `true`/`false`/`null` literals lowercase.

The verifier: parse downloaded text → extract + remove `signature` →
canonicalize remaining map → verify `sig` over those bytes with the
`keyId`'s public key. The publisher (a future/offline tool, not this
slice) canonicalizes identically — the canonical form is specified
here precisely so a non-Dart publisher can reproduce it.

Why not sign the raw downloaded bytes: mirrors may re-serve with
different whitespace; byte-signing would make every mirror's bytes
part of the trust contract. Canonicalization keeps the trust on the
*content*.

### 2.3 Envelope

```dart
class CommunitySignature {
  final String keyId;      // e.g. 'libreapp-index-2026-01'
  final String algorithm;  // must be exactly 'ed25519'
  final String sig;        // base64, 64 bytes when decoded
}
```

Verification rejects: unknown `algorithm`, undecodable `sig`, `sig`
not 64 bytes, unknown `keyId`, or a failed `verify`. Any rejection →
the whole doc is skipped (never partially merged).

## 3. Trust roots: pinned keys, no TOFU

### 3.1 Decision

**Pinned Ed25519 public keys, shipped with the app; no TOFU.**
TOFU on a store index lets a first-download MITM win forever — exactly
the attack a signature scheme exists to prevent. The trust root is the
app distributor (same party that ships the curated seed); the community
aspect is *curation at scale*, not trust-on-first-use.

### 3.2 Key storage and rotation

- Pinned keys live in `store_host` as a host-internal constant map
  `kCommunityTrustKeys: {keyId: base64PublicKey}` (new file
  `src/identity/community_trust.dart`, NOT exported — like the seed).
- The envelope's `keyId` selects the key. Multiple keys may be pinned
  simultaneously — rotation is overlap: pin new key in an app update,
  curators start signing with the new key, old key is removed in a
  later update. **Rotation ships via app update** (documented
  limitation, §8: no in-band revocation list in v1).
- v1 ships with a clearly-marked **placeholder** bootstrap key
  (`libreapp-index-bootstrap`, comment: *"PLACEHOLDER — replace at the
  project's key ceremony before publishing any real index"*). The
  private half is held by nobody; the machinery (verify path, keyId
  lookup, tamper rejection) is real and fully tested with ephemeral
  test keys. Shipping a real-looking key nobody controls would be
  dishonest; shipping the format with a labeled placeholder is not.

### 3.3 What's explicitly NOT claimed

- No certificate chain, no expiry checking on keys, no revocation.
  A compromised curator key can sign malicious mappings until an app
  update removes it (§6 covers the blast radius).
- Key provisioning by the user (dropping a pubkey file) is NOT
  supported in v1 — one trust store, one format, no configuration
  surface to get wrong. (Considered and rejected: it trades a clear
  trust story for flexibility nobody asked for.)

## 4. Mirrors: operator-set URL list, tried in order

- Flag `phase3.community.mirrors`: comma-separated HTTPS URLs
  (house pattern — same shape as `catalog.backend_order`). Default:
  empty. **Empty mirror list → no fetch, ever.**
- URLs are tried **in order**; first fully-verified doc wins. A mirror
  that fails (network error, bad JSON, bad signature) is skipped and
  the next is tried. All fail → stale index kept, failure reported,
  nothing thrown (§5).
- Only `https://` URLs are accepted; anything else is skipped with a
  diagnostic (an `http://` mirror defeats the point of signatures
  against a network attacker — defense in depth, not the primary
  defense).
- Mirror *discovery* (DNS, signed mirror lists, DHT) is future work.
  v1: the operator sets the list. Honest and sufficient for dogfooding.

### Flags (all ADR-010: owner `libreapp-center`, removal `2027-06-30`)

| flag | default | meaning |
|---|---|---|
| `phase3.identity.enabled` | `false` | master switch (exists) |
| `phase3.community.enabled` | `false` | opt-in to community distribution |
| `phase3.community.mirrors` | `''` | comma-separated HTTPS mirror URLs |

Fetch happens only when **all three** hold: identity enabled, community
enabled, mirrors non-empty. There is **no automatic download**: refresh
is an explicit `StoreHost.refreshCommunityIndex()` call (a later UI
slice may add a manual trigger; nothing in this slice fetches on a
timer or at startup).

## 5. Update flow: fetch → verify → atomic swap → reload

`Future<CommunityRefreshResult> StoreHost.refreshCommunityIndex()`:

```
1. Gate: identity+community enabled, mirrors non-empty.
   Otherwise return CommunityRefreshResult.skipped(reason).
2. For each mirror URL (https only):
   a. bytes = await transport.fetch(url)          # injectable transport
   b. doc = parse JSON (object) else continue
   c. envelope = extract signature else continue   # unsigned → skip
   d. verify(envelope, canonical(doc-envelope)) else continue
   e. atomic write: temp file + rename to the community layer path
   f. await reloadIdentityIndex()
   g. return CommunityRefreshResult.ok(entryCount, generatedAt, mirror)
3. All mirrors failed → return
   CommunityRefreshResult.failed(errorsByMirror). The previous
   community file (if any) is untouched; the in-memory index is
   unchanged.
```

Properties:

- **Verify-before-write**: the community layer file is only replaced
  *after* a doc fully verifies. Rollback on failed verification =
  don't write (the old file stays). There is no "revert" path because
  there is never an unverified write.
- **Atomic swap**: write to `<path>.tmp` + rename — a crash mid-write
  never leaves a half-written community layer.
- **Never mutate the seed or the local overlay.** The community layer
  is its own file:
  `~/.local/share/libreapp-center/identity-community.json`
  (`HOME`-relative, same convention as the overlay; no community file
  when `HOME` is absent → refresh reports `skipped`).
- **Offline behavior**: transport throws → caught per mirror → all
  fail → stale index, result `failed`, **no throw, no startup block**.
  Startup never fetches (no auto-download, §4) — the offline story is
  structural, not a catch block.
- **Layer order** (deviation from HLD §4.2, deliberate): load order is
  now **seed → community → local overlay** (highest priority last).
  HLD listed community as layer 3 (top). Changed because: the local
  overlay is the *user's own data* — a community update must never
  silently override a user's manual correction. The community layer
  still outranks the seed, which is exactly why §2–§3 exist. This
  deviation is recorded here; HLD §4.2 is amended by this note.

### Result type

```dart
class CommunityRefreshResult {
  const CommunityRefreshResult.ok({
    required this.entryCount,
    required this.generatedAt,  // from the doc; informational
    required this.mirror,
  });
  const CommunityRefreshResult.skipped(this.reason);
  const CommunityRefreshResult.failed(this.errorsByMirror);
  // exactly one of ok/skipped/failed is set; simple `isOk` etc.
}
```

A result object, not a throw: refresh is an operator-initiated
maintenance action, and "all mirrors down" is an expected outcome, not
an exceptional one. (Contrast: `saveOverlay` throws `StateError` on
unrecoverable I/O because silent data loss is worse than a throw.)

## 6. Reload API and the reload contract

Slice 1's honest gap: the index "loads lazily on first call and is
cached for the host's lifetime — no reload API". Same class as slice
2's preference-store gap. The reload contract, defined here:

```dart
/// Drops the cached identity index and resolver. The next
/// [resolveIdentity] call reloads from disk (seed + community layer +
/// local overlay). Never throws: worst case the next load yields the
/// seed-only index (FileIdentityIndexStore.load never throws).
Future<void> StoreHost.reloadIdentityIndex();
```

- `refreshCommunityIndex()` calls it internally after a verified swap,
  so the resolver picks up new layers without a host restart.
- It is also public for operators/tests: fix the overlay by hand,
  call reload, resolution reflects it.
- Concurrency: reload-while-resolving is safe — the swap replaces
  immutable `IdentityIndex`/`IdentityResolver` references; in-flight
  resolutions finish on the old index (no tearing, no locks needed
  beyond the existing lazy-init).
- `FileIdentityIndexStore` stays stateless: `load()` **is** the reload
  primitive (it gains an additive `communityPaths` parameter; layer
  order seed → community → local). No new store API needed.
- Slice 2's `SourcePreferenceStore` loads-once-per-host-lifetime gap is
  NOT fixed here — recorded in §8. (Same shape, separate slice.)

## 7. Threat model

Short and honest. A community index is *data*, never code.

**What a malicious index CAN do** (assuming a compromised or rogue
curator key — the only way a malicious doc passes verification):

- **Mislabel apps.** Remap backend keys / signals to wrong canonical
  IDs → merged cards show the wrong variant as "Firefox", and
  install/remove/update act on the attacker's chosen variant. This is
  the primary blast radius: **UI-level misattribution leading the user
  to install/remove the wrong package**.
- Add bogus aliases, poison display names.

**What it CANNOT do:**

- **Escalate install privileges.** Installs execute through the
  backends' own auth (snapd polkit, PackageKit/pkexec, flatpak
  session) — the index influences *which* package is named, never
  *how* it's installed. A malicious index cannot install without the
  user's normal auth prompts.
- **Execute code.** Entries are strings; the resolver never evaluates
  them. (A hostile `displayName` is rendered as text — UI escaping is
  the UI's existing job.)
- **Exfiltrate or phone home.** The fetcher only GETs operator-set
  mirror URLs; the index itself triggers no network.
- **Persist against the user.** The local overlay outranks community
  (§5): any mapping can be corrected by hand and survives community
  updates.

**Residual risks (accepted, documented):**

1. Compromised curator key → malicious mappings accepted until an app
   update rotates the key (§3.2). No in-band revocation in v1.
2. Stale-mirror replay: a mirror serving an old signed doc is
   *accepted* (freshness is not gated, §1) — an attacker who captures
   a mirror can only roll mappings *back*, not invent new ones, and
   only until the operator notices `generatedAt` lag.
3. Unsigned-doc stripping is a non-attack (§1): unsigned docs never
   merge.

## 8. Explicitly not in this slice (deferred, honestly)

- UI trigger for refresh (manual "update index" affordance) — later
  slice; the API exists, the button doesn't.
- Manifest/sharded distribution; mirror discovery (signed mirror
  lists); in-band key revocation / expiry.
- `SourcePreferenceStore` reload (slice 2 gap; same shape as §6).
- The offline publisher/signing tool (key ceremony artifacts).
- AppStream catalog harvesting into the community layer.
- Fuzzy matching. Ever.

## 9. Test matrix

Unit tests (fake transport implementing the fetch seam; ephemeral
Ed25519 keypairs generated in-test — never the placeholder key):

- `canonicalJsonBytes`: key sorting (nested), no-whitespace form,
  string escaping, round-trip stability; differs when any value
  differs.
- `CommunityTrustStore`/`verifyCommunityDoc`: valid envelope verifies;
  tampered entry byte → reject; wrong key → reject; unknown keyId →
  reject; bad algorithm → reject; malformed sig → reject; unsigned doc
  → reject (skip, not merge).
- `CommunityIndexFetcher` (fake transport): first mirror fails, second
  verifies → merged; all fail → previous file untouched, result
  `failed`, in-memory index unchanged; non-https URL skipped.
- Atomicity: temp+rename used (assert via fake file-system or by
  observing no partial file after a mid-write failure injection).
- `FileIdentityIndexStore.load` with `communityPaths`: layer order
  seed < community < local (user overlay overrides community on
  conflict; community overrides seed).
- `StoreHost.reloadIdentityIndex`: mutate overlay on disk → reload →
  resolution reflects it; no restart.
- `refreshCommunityIndex` gating: flag off → `skipped`; mirrors empty
  → `skipped`; `HOME` absent → `skipped`.
- Offline: transport throws for all mirrors → `failed`, stale index
  intact, no throw.
- Contract version: unchanged (`0.4.0`) — no contract changes in this
  slice (all new API is host-internal or additive host methods).

Gates: `melos test`, `melos analyze --fatal-infos`,
`melos format:exclude`, `scripts/dep_trace.py` zero new violations.
