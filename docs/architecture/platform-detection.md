# Platform detection + graceful degradation — HLD + LLD

Parents: [host-wiring.md](host-wiring.md), [parallel-check-updates.md](parallel-check-updates.md)
(§11 style for fan-out/timeout conventions),
[operation-state-machine.md](operation-state-machine.md) (§7 error taxonomy).

Today the app has zero distro detection: `/etc/os-release` is never
parsed, and `buildStoreHost()`
(`packages/app_center/lib/store/store_host_wiring.dart`) registers all
four backends unconditionally on every system. Host-side degradation
already works — `enabledBackends()` + `_raceOne` exclude missing or
hanging backends — but two things break outside Ubuntu:

1. **The shell is Ubuntu-shaped.** `store_pages.dart` always shows the
   Explore/Games nav tiles, whose pages import snapd directly
   (`explore_page.dart` → `CategoryBanner(SnapCategoryEnum.*)`). On a
   Fedora box with no snapd these tiles lead to a broken shell.
2. **The deb backend lies on Fedora.** `BackendDeb` probes PackageKit
   via D-Bus, and PackageKit exists on Fedora — so the probe passes and
   RPM packages come back labeled `AppSource.deb`. The probe is
   *honest* (PackageKit is reachable); the label is not. An apt/dpkg
   backend can never be honest on an rpm system.

This slice adds platform identity: detect the distro family once at
startup, seed the backend kill switches accordingly, and hide the
snap-shaped nav chrome where snap doesn't belong. `isAvailable()`
remains the runtime truth for liveness — detection seeds defaults, it
does not replace probing.

## HLD

### 1. Platform model — DECIDED: `PlatformInfo` parsed from `/etc/os-release`

`PlatformInfo` is a plain data class (identity, not behavior):

- `id` — raw `ID=` field (`ubuntu`, `fedora`, `arch`, …).
- `idLike` — raw `ID_LIKE=` field split on whitespace
  (`debian`, `fedora rhel`, `arch`, …).
- `prettyName` — raw `PRETTY_NAME=` (display only; never classified on).
- Derived predicates: `isDebianLike`, `isFedoraLike`, `isArchLike`,
  `isUnknown`. Exactly one is true.

Classification rules (explicit, in this order):

1. **debian-like** — `id` ∈ {`ubuntu`, `debian`, `linuxmint`, `pop`,
   `elementary`, `zorin`, `kali`, `raspbian`} **or** `idLike` contains
   `debian` or `ubuntu`. (Covers Ubuntu derivatives that forget to set
   `ID_LIKE`.)
2. **fedora-like** — `id` ∈ {`fedora`, `rhel`, `centos`, `rocky`,
   `almalinux`, `nobara`, `opensuse-leap`, `opensuse-tumbleweed`,
   `sles`} **or** `idLike` contains `fedora`, `rhel`, `suse`, or
   `opensuse`. Name is historical: it means the RPM family (dnf/yum/
   zypper). The seeded defaults are identical for all of them today;
   the family label exists so a future `backend.rpm` slice can branch
   on it.
3. **arch-like** — `id` ∈ {`arch`, `manjaro`, `endeavouros`, `garuda`,
   `artix`} **or** `idLike` contains `arch`.
4. **unknown** — everything else, *including* parse failure: missing
   file, unreadable file, or no `ID=` line. Detection **never throws**;
   the worst case is `PlatformInfo.unknown()`.

Detection runs **once**, synchronously, in the composition root
(`buildStoreHost`). The reader is injectable (see §8): production reads
`/etc/os-release`; tests pass a path or raw content. No caching needed —
a 300-byte file read at startup, twice at most (detection + provider).

### 2. Detection vs probing — two different questions, two layers

| Question | Answered by | When | Cost | Failure mode |
|---|---|---|---|---|
| *What distro is this?* (identity) | `detectPlatform()` | Once at startup | One file read | → `unknown`, seeded defaults == compiled defaults (today's behavior) |
| *Is this backend usable right now?* (liveness) | `StoreBackend.isAvailable()` | Per query, inside every fan-out | <200ms (exam-guarded) | → backend excluded, partial results |

Layering rule: **detection seeds flag defaults; `isAvailable()` remains
the runtime truth.** Detection never consults sockets, binaries, or
D-Bus; probing never consults `/etc/os-release`. Consequences:

- Ubuntu without snapd: detection says debian-like (snap stays enabled
  by default), the probe excludes snap at query time. Same as today.
- Fedora with manually-installed snapd: detection seeds
  `backend.snap.enabled=false`; the probe would pass, but the flag is
  the kill switch — the backend stays out until the user flips it.
  This is intentional: on non-debian the *default* is off; the user
  retains the final word (§3).
- A probe regression (e.g. the Fedora deb mislabel) is fixed by
  seeding, not by making probes distro-aware. Probes stay dumb and
  honest: "PackageKit is reachable" is true on Fedora; the *decision*
  that an apt backend doesn't belong there lives in the seed table.

### 3. Flag seeding — DECIDED: a seeded-defaults layer under user overrides

`buildStoreHost` becomes: detect → seed → construct → register.

Seed table (the only per-platform behavior in this slice):

| Platform family | `backend.snap.enabled` | `backend.deb.enabled` | `backend.flatpak.enabled` | `backend.appimage.enabled` |
|---|---|---|---|---|
| debian-like | `true` (today's default) | `true` (today's default) | `true` (unchanged) | `false` (unchanged) |
| fedora-like | `false` | `false` | `true` (unchanged) | `false` (unchanged) |
| arch-like | `false` | `false` | `true` (unchanged) | `false` (unchanged) |
| unknown | — (compiled default) | — (compiled default) | — | — |

Decisions behind the table:

- **snap off on non-debian.** snapd is Ubuntu-canonical; `BackendSnap`
  probes the snapd socket, which is absent on stock Fedora/Arch. The
  host already excludes it via the probe — seeding off just makes the
  *intent* explicit and gates the nav tiles (§6).
- **deb off on non-debian.** This is the honesty fix: `BackendDeb` is
  apt/dpkg-specific; on Fedora it would pass its PackageKit probe and
  return RPM packages labeled `AppSource.deb`. Disabling is the honest
  move — mislabeled results are worse than no results. A real
  `backend.rpm` / `backend.pacman` is a FUTURE slice (§7).
- **flatpak unchanged everywhere.** Flatpak is distro-agnostic by
  design; its probe (`flatpak --version`) is the truth.
- **appimage unchanged** (`false` everywhere). Seeding must not widen a
  backend that is still dogfooding-gated.
- **unknown → today's behavior.** The compiled `_defaults` are the
  Ubuntu-shaped status quo; an unrecognized distro gets exactly what it
  gets today. No regression possible from a detection miss.

**Detected-default vs user-disabled, distinguished.** Today
`MapFeatureFlags` has one map: `_values` (seeded with compiled
`_defaults`, mutated by `setFlag`). Seeding the detected defaults
through `setFlag` would conflate "Fedora seeded snap off" with "user
turned snap off" — indistinguishable in the map, and a later
`storeFlagsProvider` rebuild would re-seed over user choices. DECIDED:
a **seeded-defaults layer** — `MapFeatureFlags.seedDefault(key, value)`
writes a separate `_seeded` map consulted *after* `_values` (user
mutations) and *before* `_defaults` (compiled):

```
isEnabled(key) = _values[key] ?? _seeded[key] ?? _defaults[key] ?? false
```

- `seedDefault` is called only at startup from `buildStoreHost`, before
  any user mutation can exist. It emits no `changes` event (nobody is
  listening yet).
- `setFlag` always wins (user / Settings UI / tests). A Fedora user who
  installed snapd flips `backend.snap.enabled=true` and it sticks —
  re-seeding never happens because `buildStoreHost` runs once.
- Additive to `flags.dart`; existing readers untouched; `isEnabled` /
  `getInt` / `getString` semantics unchanged for unseeded keys.

`catalog.backend_order` (`flatpak,snap,deb`) is left alone — it is a
reserved flag, not yet consumed (host-wiring.md), so seeding it buys
nothing.

### 4. Probe caching — DECIDED: host-side per-backend memoization, 30s TTL

`isAvailable()` is called per fan-out per backend (`search`,
`installedDetailed`, `checkUpdatesDetailed`) — three fan-outs × four
backends per UI session tick, each probe spawning a socket connect,
D-Bus handshake, or CLI exec. The exam guarantees <200ms per probe, but
nothing stops the host from being smarter.

DECIDED: **`StoreHost` memoizes `isAvailable()` results per backend id
with a 30s TTL**, keyed off a new flag `host.probe_cache_ttl_ms`
(default `30000`; `<= 0` disables caching entirely, mirroring the
`<= 0 → default` convention of the timeout flags — a cache you can
disable is a debugging tool, not a feature).

| Candidate | Verdict | Reason |
|---|---|---|
| No caching (status quo) | Rejected | 12+ probe round-trips per poll tick; each is a process spawn or D-Bus call. Cheap individually, wasteful in aggregate, and every probe is a flake surface. |
| Backend-side caching | Rejected | Requires touching all four backends + the exam; the contract says `isAvailable()` is "safe to call twice", which permits host-side caching but does not require backends to implement it. Also untestable per-backend without new seams. |
| **Host-side memoization, 30s TTL** | **Chosen** | One place, additive to `host.dart`, testable with an injectable `Clock` (TTL expiry = clock advance in tests; the engine never calls `DateTime.now()` directly). The <200ms exam is untouched: the exam probes backends, not the host. |

Why the semantics stay safe:

- **Stale `true`** (backend died within the TTL): the fan-out still
  includes it, the fetch fails, `_raceOne` excludes it → partial
  results. The existing degradation path absorbs the error; the cache
  only cost one failed fetch.
- **Stale `false`** (backend recovered within the TTL): excluded for at
  most 30s, then the next fan-out re-probes. Bounded, self-healing.
- **Flag-off backends bypass the cache entirely** (flag filter runs
  before the probe, same as today) — seeding changes take effect
  immediately, never wait out a TTL.
- The memoized probe still runs *inside* the `_raceOne` budget in the
  detailed fan-outs (a cache read is instant; a cache miss re-probes
  under the same timeout). No contract change.

**Amendment (2026-09-27):** expiry is **lazy via an injectable `Clock`**,
not a `TimerFactory` invalidation timer. Each cache entry carries its
probe timestamp; a read older than the TTL re-probes. Rationale: expiry
never needs to fire proactively (unlike the stall watchdog, which must
act at its deadline), so arming a 30s timer per probe bought nothing —
and it leaked pending timers into every `StoreHost` construction site,
tripping the test framework's teardown invariant in 22 app widget tests
that build real hosts. Observable semantics are unchanged (30s TTL,
`<= 0` disables, per-backend isolation, flag-off bypass).

### 5. Host behavior — DECIDED: `StoreHost` logic unchanged

Seeding happens in the composition root; the host only reads
`backend.<id>.enabled` as it does today. Consequences, all already true
in `host.dart`, confirmed as specified behavior:

- Only available + enabled backends participate in fan-outs (the
  detailed fan-outs filter on the flag; `search()` goes through
  `enabledBackends()`). No `StoreHost` change.
- **`enqueue` on a platform-disabled backend throws typed
  `BackendUnavailableException`** (`debugDetail: 'backend <id> disabled
  by flag'`) — the existing flag check in `enqueue()` covers this; a
  Fedora user tapping a stale deep link to a snap gets a typed error,
  not a raw crash. No change needed.
- `getDetails` on an unregistered id throws the same typed exception
  (unchanged).

In other words: this slice is a composition-root-only change plus the
`seedDefault` additive in `flags.dart` and the probe-cache additive in
`host.dart`. `store_contracts` is untouched — `StoreBackend` gains
nothing.

### 6. UI degradation — minimal, explicit scope

**In scope** (the smallest change that un-breaks the shell):

- New provider `backendEnabledProvider` (`Provider.family<bool,
  String>`, in `lib/store/`, next to `storeFlagsProvider`): reads
  `flags.isEnabled('backend.<id>.enabled')` — the *seeded* flag, sync,
  no probe awaited. Nav visibility is a startup decision; query-time
  liveness stays in the fan-outs (§2).
- `store_pages.dart`: the `pages` list filters the Explore and Games
  tiles on `ref.watch(backendEnabledProvider('snap'))`. Both pages are
  snapd-backed legacy surfaces (Explore's `CategoryBanner` /
  `CategorySnapList` over `SnapCategoryEnum`; Games likewise). When snap
  is seeded off — Fedora, Arch — the tiles vanish; the shell stops
  advertising a store it can't back.
- Manage tile stays unconditionally: it hosts the unified pages, which
  degrade per-backend already.

Why the flag and not a live probe for the nav: the snap probe can take
up to its 2s socket timeout on a broken system; the nav must not await
that at startup. The seeded flag *is* the composition root's verdict.

**Explicitly out of scope** (with reasons):

- **Explore/Games/Manage page bodies.** They are legacy snapd-backed
  pages mid-strangler-fig; rewriting them to read the host is the
  strangler's job, not this slice's. Hiding their nav entries removes
  the broken entry point; deep links (`snap://`) to them on snap-less
  systems keep today's behavior (typed error from `enqueue`, legacy
  page shows its own empty/error state).
- **Legacy Manage/search default paths.** `pages.manage.unified` /
  `pages.updates.unified` remain the strangler switches; platform
  seeding does not flip them.
- **Any new user-visible strings.** Hiding a tile needs none. If a
  future slice needs copy, it goes in `app_en.arb` only (repo rule).

### 7. Out of scope, explicitly

- `backend.rpm`, `backend.pacman`, `backend.nix` — the fedora-like /
  arch-like families exist in `PlatformInfo` precisely so these slices
  have something to branch on, but no backend is added here.
- `reachability(Vehicle)` from `lld.md` — aspirational, does not exist
  in code; not built in this slice.
- Settings → Backends UI (the surface where a user would flip a seeded
  kill switch). The `setFlag` override path exists; the UI does not.
- Ratings. Unrelated.

## LLD

### 8. Interface contracts (all additive)

**`PlatformInfo`** — new, `app_center`
(`lib/store/platform_detection.dart`; composition-root concern, so it
lives in `lib/store/` next to `store_host_wiring.dart` — no
`store_host` or `store_contracts` change, `dep_trace.py` boundary
unaffected):

```dart
/// Distro identity parsed from /etc/os-release. Identity only — never
/// liveness (see platform-detection.md §2).
class PlatformInfo {
  const PlatformInfo({
    required this.id,        // raw ID= field, e.g. 'ubuntu'
    required this.idLike,     // raw ID_LIKE= split on whitespace
    required this.prettyName, // raw PRETTY_NAME=, display only
  });

  const PlatformInfo.unknown()
      : id = '', idLike = const [], prettyName = '';

  final String id;
  final List<String> idLike;
  final String prettyName;

  bool get isDebianLike; // §1 rule 1
  bool get isFedoraLike; // §1 rule 2
  bool get isArchLike;   // §1 rule 3
  bool get isUnknown;    // §1 rule 4 — exactly one predicate is true
}
```

**`OsReleaseReader`** — the test seam:

```dart
/// Reads /etc/os-release content. Production reads the file;
/// tests inject a path or raw content.
typedef OsReleaseReader = String? Function();
```

**`detectPlatform`**:

```dart
/// Parse the distro family. NEVER throws: unreadable file, missing
/// ID=, or garbage content all yield [PlatformInfo.unknown()].
PlatformInfo detectPlatform({OsReleaseReader? reader});
```

Production reader: `File('/etc/os-release').readAsStringSync()` wrapped
in try/catch → `null` on any failure. Parsing: line-split,
`KEY=value` with optional quotes stripped, first `ID=` wins, `ID_LIKE`
split on whitespace. Unknown keys ignored.

**`seedPlatformBackendDefaults`** — the seed table as a pure function
(no I/O, trivially unit-tested):

```dart
/// Apply the §3 seed table: writes only the seeded-defaults layer
/// (MapFeatureFlags.seedDefault), so later setFlag calls (user,
/// Settings UI, tests) always win.
void seedPlatformBackendDefaults(FeatureFlags flags, PlatformInfo platform);
```

Requires `FeatureFlags` to expose the seeding write. DECIDED: add to
the `FeatureFlags` interface in `store_contracts`? No — keep the
interface frozen; `MapFeatureFlags.seedDefault` is a concrete-class
method and `buildStoreHost` holds the concrete `FeatureFlags`. Hmm —
`buildStoreHost` takes `FeatureFlags` (the interface). Two options:
(a) extend the `FeatureFlags` interface with `seedDefault` (interface
change, but additive — one method, default no-op? Dart interfaces can't
have default no-op cleanly... they can via `extension` but that's
hacky); (b) `seedPlatformBackendDefaults` takes `MapFeatureFlags`
concretely. DECIDED: (b) — the seeding function takes
`MapFeatureFlags`; the composition root owns the concrete instance
(`storeFlagsProvider` builds `MapFeatureFlags`). The interface stays
frozen; the host keeps reading through the interface. Document the
slight concreteness as intentional: seeding is a startup-only,
composition-root-only operation.

Wait — check: does `FeatureFlags` interface live in store_contracts?
Yes (`packages/store_contracts/lib/src/flags.dart`, and `MapFeatureFlags
implements FeatureFlags`). And `buildStoreHost(FeatureFlags flags, …)`
— the provider passes the concrete `MapFeatureFlags`. So (b) means
`buildStoreHost` internally does
`if (flags is MapFeatureFlags) seedPlatformBackendDefaults(flags,
platform)`. Slightly awkward. Alternative (c): `buildStoreHost` gains
an optional `PlatformInfo? platformOverride` test seam and does the
seeding itself against `MapFeatureFlags` after a type check. That's (b)
with the seam in one place. DECIDED: (b/c combined) —

```dart
StoreHost buildStoreHost(
  FeatureFlags flags, {
  …transports…,
  // Test seam: inject a fake platform. Production always passes null
  // and detection runs against /etc/os-release.
  PlatformInfo? platformOverride,
  OsReleaseReader? osReleaseReader,
}) {
  final platform = platformOverride ?? detectPlatform(reader: osReleaseReader);
  if (flags is MapFeatureFlags) {
    seedPlatformBackendDefaults(flags, platform);
  }
  final host = StoreHost(flags: flags);
  …register backends unconditionally, as today…
  return host;
}
```

Registration stays unconditional (the flag does the filtering — same
as today; also preserves the appimage doc fix in the appendix). The
`is` check is honest: with a foreign `FeatureFlags` implementation the
seed is skipped and compiled defaults apply (unknown-platform
behavior). No throw either way.

**`MapFeatureFlags.seedDefault`** (additive, `store_host`):

```dart
/// Seed a *detected* default (platform-detection.md §3). Consulted
/// after user mutations (_values) and before compiled _defaults:
///   _values[key] ?? _seeded[key] ?? _defaults[key]
/// Startup-only: emits no changes event. Later setFlag() always wins.
void seedDefault(String key, Object value);
```

`isEnabled`/`getInt`/`getString` each gain the `?? _seeded[key]` step.
No other behavior change.

**Probe cache** (additive, `host.dart`): private
`Map<String, _ProbeCacheEntry>` on `StoreHost`
(`_ProbeCacheEntry{bool value, DateTime…}` — no: the host never reads
the wall clock; expiry via `TimerFactory`-armed invalidation or
deadline comparison against a `DateTime Function()` seam. DECIDED:
store `DateTime expiresAt` using an injectable `DateTime Function()`
defaulting to `DateTime.now` — hmm, the watchdog precedent says "the
engine never reads the wall clock". Cleaner: on a cache miss, probe and
arm a single-shot `TimerFactory` invalidation for the TTL; TTL<=0 →
no caching. Fake timers make expiry deterministic in tests. Cache is
consulted wherever `isAvailable()` is awaited: `enabledBackends()` and
`_raceOne`. One shared private helper `_isAvailableCached(backend)`.)

New flag (flags.dart `_defaults`, ADR-010 owner + removal date):

```dart
'host.probe_cache_ttl_ms': 30000, // isAvailable() memoization TTL
    // (docs/architecture/platform-detection.md §4). <= 0 disables
    // caching. Read at call time; the cache itself is the memo.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
```

**Providers** (`app_center`, `lib/store/`):

```dart
/// Distro identity, detected once at startup. Sync — one file read.
final platformInfoProvider = Provider<PlatformInfo>(
  (_) => detectPlatform(),
  name: 'platformInfoProvider',
);

/// Seeded kill switch for one backend id ('snap', 'flatpak', 'deb',
/// 'appimage'). Sync flag read — nav visibility must not await probes.
final backendEnabledProvider = Provider.family<bool, String>(
  (ref, id) => ref.watch(storeFlagsProvider).isEnabled('backend.$id.enabled'),
  name: 'backendEnabledProvider',
);
```

(`platformInfoProvider` re-reads the file rather than sharing
`buildStoreHost`'s instance — one extra 300-byte read at startup,
keeps both call sites independent and testable. Note it as a deliberate
non-sharing.)

### 9. Test matrix

`app_center` — `test/platform_detection_test.dart` (pure Dart, no
Flutter):

detectPlatform (content-override reader):
1. Ubuntu content (`ID=ubuntu`, `ID_LIKE=debian`) → `isDebianLike`,
   not others; `id == 'ubuntu'`.
2. Debian with no `ID_LIKE` → `isDebianLike` (rule 1 covers bare `ID`).
3. Fedora (`ID=fedora`) → `isFedoraLike`. openSUSE Leap
   (`ID=opensuse-leap`, `ID_LIKE="suse opensuse"`) → `isFedoraLike`.
4. Arch (`ID=arch`) and Manjaro (`ID=manjaro`, `ID_LIKE=arch`) →
   `isArchLike`.
5. Missing file (reader returns null), empty content, garbage
   (`"hello\n"`), `ID=` absent → `PlatformInfo.unknown()`,
   `isUnknown`, and — critically — **no throw** on any of them.
6. Precedence: content matching both debian and fedora rules can't
   happen in practice; assert rule order anyway with a synthetic
   `ID_LIKE="debian fedora"` → debian-like (rule 1 first).

seedPlatformBackendDefaults (fresh `MapFeatureFlags` each):
7. debian-like → `backend.snap.enabled == true`,
   `backend.deb.enabled == true` (today's defaults preserved).
8. fedora-like → snap `false`, deb `false`, flatpak `true`, appimage
   `false`.
9. arch-like → same as fedora-like.
10. unknown → **zero seeded keys**: `isEnabled` for every backend key
    equals the compiled default (today's behavior, byte-identical).
11. User override wins: seed fedora-like, then
    `setFlag('backend.snap.enabled', true)` → `isEnabled` true.
    And the reverse: seed debian-like, `setFlag(..., false)` → false.
    (Proves the `_values` → `_seeded` → `_defaults` precedence.)
12. `seedDefault` emits no `changes` event (listen, seed, expect
    silence) while `setFlag` does.

`buildStoreHost` (fake `platformOverride`):
13. Fedora override + stub backends → `host.enabledBackends()` excludes
    snap and deb (flags seeded off); flatpak included when its stub
    probes true.
14. `enqueue(install, AppIdentity(backendId: 'snap', …))` on the Fedora
    host → throws `BackendUnavailableException` (typed, not raw).
15. Unknown override → all compiled defaults → identical backend set to
    today's `buildStoreHost`.

`store_host` — probe cache (fake `TimerFactory`, counting stub backend):
16. Two `enabledBackends()` calls, TTL not expired → backend's
    `isAvailable()` invoked once.
17. Advance fake clock past TTL → next call re-probes (invoked twice).
18. `host.probe_cache_ttl_ms <= 0` → never caches (invoked every call).
19. Flag-off backend never probes (cache bypass): seed snap off,
    `enabledBackends()` → snap's `isAvailable()` invoked zero times.
20. Cache is per backend id: one backend's cached `false` doesn't affect
    another.

`app_center` — nav (widget test on the pages list builder, or provider
unit test if the tile filter is extracted):
21. `backendEnabledProvider('snap')` false → Explore/Games tiles absent
    from the `pages` list; Manage present.
22. true → all three present (today's behavior).

### 10. Rollout / risk

- **Zero behavior change on Ubuntu.** debian-like seeds exactly the
  compiled defaults; unknown (detection failure) seeds nothing. The
  only new runtime behavior anywhere is the probe cache (30s TTL,
  self-correcting per §4) and two hidden nav tiles on non-debian.
- **No flag-gate needed.** Unlike the strangler slices, there is no
  legacy path to preserve: detection failure *is* the legacy path.
- `dep_trace.py`: `platform_detection.dart` lives in `lib/store/`
  (host-layer, like `store_host_wiring.dart`) and imports no
  `backend_*` — boundary clean. `PlatformInfo` consumed by
  `store_pages.dart` (UI) is fine: it's a data class, not a backend.
- Risk: a distro whose `ID_LIKE` is missing *and* whose `ID` isn't in
  the table (e.g. a new Ubuntu remix with a novel `ID=`) → unknown →
  today's behavior. Safe direction.
- Risk: `seedDefault` on a foreign `FeatureFlags` impl is skipped
  silently (the `is` check). Only `MapFeatureFlags` is ever
  constructed in this codebase (`storeFlagsProvider`), so this is a
  theoretical seam, not a live path.

### 11. Honest limitations

- **Nav uses the seeded flag, not liveness.** A Fedora user who
  installs snapd and flips the kill switch gets the Explore/Games tiles
  back; a Fedora user who installs snapd but doesn't know about the
  switch doesn't. The switch has no Settings UI yet (§7) — flipping it
  today means `setFlag` in code or a test. Stated, not hidden.
- **Explore/Games pages themselves are untouched.** If a snap-less user
  reaches them via a `snap://` deep link, they see the legacy page's
  own empty/error state, not a platform-aware message. The strangler
  slices own those pages.
- **Probe cache staleness is real but bounded** (§4): ≤30s of wrong
  exclusion, and a wrongly-included dead backend still degrades to
  partial via `_raceOne`. The cache never *creates* a failure mode that
  the fan-outs don't already handle.
- **The deb backend is disabled, not fixed, on Fedora.** Users lose
  PackageKit results there until `backend.rpm` lands. That's the honest
  trade the §3 table makes: no results beats mislabeled results.
- **`platformInfoProvider` double-reads `/etc/os-release`.** One extra
  300-byte sync read at startup; deliberate (§8), not an oversight.
- **No telemetry on detection outcome.** `store_host` owns no log sink
  (parallel-check-updates.md §12); if a sink ever lands, log the
  detected family at startup — "unknown on a mainstream distro" is the
  signal that the §1 table needs a new row.

### 12. Appendix — drive-by doc fix (appimage "never registered")

`flags.dart` currently comments `backend.appimage.enabled` as
"`false` → backend never registered". That is wrong: `buildStoreHost`
registers `BackendAppimage` **unconditionally** (same as the other
three); the flag only filters it out of fan-outs and blocks `enqueue`
via the typed `BackendUnavailableException`. This slice fixes the
comment to say what the code does:

```dart
// Kill switch for the AppImage backend plugin (Phase 1): false →
// backend excluded from fan-outs and enqueue throws
// BackendUnavailableException; the backend is still registered
// (registration is unconditional — the flag is the filter).
// Default off: new backend, needs dogfooding.
// Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
'backend.appimage.enabled': false,
```

No code change — comment only. (The same unconditional-registration
fact is why the §3 seed table works without touching registration.)

---

*Slice contract: additive only. No `store_contracts` changes, no
`StoreBackend` changes, no exam changes, no `StoreHost` public-API
changes. `store_pages.dart` gains a provider watch; `flags.dart` gains
`seedDefault` + one flag; `host.dart` gains the probe cache;
`store_host_wiring.dart` gains detect → seed; one new file
`lib/store/platform_detection.dart`.*
