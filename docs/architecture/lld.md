# LLD — Interface Contracts

Parent: [hld.md](hld.md). This doc is the law: every backend plugin implements
these contracts; the UI and host depend on nothing else.

Conventions: Dart 3, `freezed` entities, Riverpod providers in the host,
`ubuntu_lints`. Contracts live in `packages/store_contracts` — the only
package the UI may import besides Flutter itself.

---

## 1. `StoreBackend` — the plugin contract

The single interface every backend implements. If it isn't here, the UI
can't ask for it.

```dart
abstract class StoreBackend {
  /// Stable machine id: 'snap', 'deb', 'flatpak', 'appimage', …
  /// MUST match ^[a-z0-9_]+$. Used in flags: backend.<id>.enabled.
  String get id;

  /// Human name for Settings → Backends. Localized by the host.
  String get displayName;

  /// What this backend can do. Host never calls a method whose
  /// capability is absent — checked, not assumed.
  Set<BackendCapability> get capabilities;

  /// Runtime availability probe. MUST be cheap (<200ms), non-blocking,
  /// and side-effect free. Called on startup and on vehicle change.
  /// e.g. snap: snapd socket reachable? flatpak: binary on PATH?
  Future<bool> isAvailable();

  /// In which ship vehicles this backend is reachable, and how.
  /// The host skips backends unreachable from the current vehicle.
  Set<VehicleReachability> reachability(Vehicle current);

  /// Search apps. Results stream as found — host renders incrementally.
  /// PRE:  query trimmed, 1..200 chars.
  /// POST: stream closes; every item has unique (id, backendId).
  /// TIMEOUT: host cancels subscription after per-backend timeout (3s).
  /// MUST NOT throw synchronously — errors arrive as stream errors.
  Stream<AppInfo> search(String query);

  /// Full details for an id previously returned by this backend.
  /// PRE:  id came from this backend (search/getInstalled).
  /// POST: AppDetails.backendId == id (this backend).
  /// THROWS: AppNotFoundException if id unknown.
  Future<AppDetails> getDetails(AppIdentity id);

  /// Installed apps managed by this backend.
  /// POST: every item has installedVersion != null.
  Future<List<AppInfo>> getInstalled();

  /// Check for updates. Should be incremental where the backend allows.
  /// POST: only apps with updateAvailable == true.
  Future<List<UpdateInfo>> checkUpdates();

  /// Begin install. Returns immediately with a handle; work is async.
  /// PRE:  capabilities contains install; id known to this backend.
  /// POST: handle.id is unique; handle.state starts at queued.
  /// IDEMPOTENT: installing an already-installed app returns a handle
  ///   that completes immediately as alreadyInstalled (no re-download).
  Future<OperationHandle> install(AppIdentity id);

  /// Begin remove. Same handle discipline as install.
  /// PRE: capabilities contains remove; app is installed by this backend.
  Future<OperationHandle> remove(AppIdentity id);

  /// Begin update of an installed app.
  /// PRE: capabilities contains update; updateAvailable == true.
  Future<OperationHandle> update(AppIdentity id);
}
```

```dart
enum BackendCapability {
  search,        // search() meaningful
  details,       // getDetails() beyond AppInfo
  install,       // install()
  remove,        // remove()
  update,       // update() / checkUpdates()
  permissions,   // exposes sandbox permission manifest
  ratings,       // native ratings source
}

enum Vehicle { snap, flatpak, nativeDeb, nativeRpm, appImage, unknown }

enum VehicleReachability {
  direct,        // full native access (native packages on host)
  viaHostExec,   // needs flatpak-spawn / snap host exec bridge
  unavailable,   // cannot work in this vehicle
}
```

**Contract rules (enforced by contract tests, §9):**

- No backend may block the UI thread. All I/O is async; heavy parsing is
  off the main isolate.
- `search` streams MUST be cancellable — when the host cancels, the backend
  stops work within 500ms (no orphaned `flatpak search` processes).
- Backends MUST NOT show their own dialogs. Auth/errors surface through
  `OperationHandle` and `StoreException`; the host renders.
- Backends MUST NOT write outside their domain. The deb backend never touches
  `~/snap`; the flatpak backend never touches dpkg state.

## 2. Normalized entities

```dart
@freezed
class AppInfo with _$AppInfo {
  const factory AppInfo({
    required AppIdentity identity,   // globally unique: backendId + backend's id
    required String name,
    required String summary,
    String? version,
    String? installedVersion,        // null = not installed
    required String iconUrl,         // host resolves/caches
    required AppSource source,       // which format, for badges
    int? installSizeBytes,
    double? rating,                  // null = no data, never 0.0-as-unknown
    bool? updateAvailable,
  }) = _AppInfo;
}

@freezed
class AppIdentity with _$AppIdentity {
  /// Globally unique across backends: 'flatpak:org.videolan.VLC'
  const factory AppIdentity({
    required String backendId,   // StoreBackend.id
    required String nativeId,    // backend's own id for the app
  }) = _AppIdentity;
}

@freezed
class AppDetails with _$AppDetails {
  const factory AppDetails({
    required AppInfo app,
    required String description,
    List<String> screenshots = const [],
    List<Permission> permissions = const [],  // empty = backend can't report
    String? license,
    String? homepage,
    String? changelog,
  }) = _AppDetails;
}

@freezed
class Permission with _$Permission {
  const factory Permission({
    required String id,          // 'network', 'home', 'camera', …
    required String description, // localized by host
    required PermissionLevel level, // normal | sensitive | dangerous
  }) = _Permission;
}
```

**Dedupe key:** `UnifiedApp` groups `AppInfo`s whose `dedupeKey` matches —
`dedupeKey` = AppStream ID when present, else `normalize(name)+publisher`
heuristic, else community override table. The UI renders one card per
`UnifiedApp` with a format picker. (Full algorithm in host; contract: every
`AppInfo` exposes the fields the pipeline needs, never null-garbage.)

## 3. `OperationHandle` — the operation state machine

One install/update/remove = one handle = one state machine. The UI binds to
this and nothing else.

## 3. `OperationHandle` — the operation state machine

One install/update/remove = one handle = one state machine. The UI binds to
this and nothing else.

**The full contract lives in
[`operation-state-machine.md`](operation-state-machine.md) — states, the
legal-transition DAG, `cancel()` semantics, progress rules, `OperationResult`,
idempotency, engine rules, crash recovery, and the exam assertions. That
document is authoritative; this section is a sketch.**

```dart
abstract class OperationHandle {
  String get id;                       // unique per operation
  AppIdentity get app;
  OperationKind get kind;              // install | remove | update
  Stream<OperationState> get state;   // updates; terminal states emit nothing further
  OperationState get current;        // latest state, synchronously

  /// Request cancellation. MUST be safe to call in any state;
  /// no-op when already terminal. Backend stops work ASAP and
  /// transitions to cancelled (never silently to failed).
  Future<void> cancel();
}

// States: queued → authenticating → preparing → downloading →
// verifying (optional) → applying → done | cancelled | failed,
// plus restoring (re-attach after restart) and cancelling (transitional).
// See operation-state-machine.md §1–§2 for the exact DAG.
```

## 4. `UnifiedCatalog` (host)

```dart
abstract class UnifiedCatalog {
  /// Fan-out search. Streams UnifiedApp groups as backends respond.
  /// PRE: query 1..200 chars.
  /// BEHAVIOR: queries all available+enabled backends in parallel;
  ///   per-backend timeout 3s (flag: catalog.search_timeout_ms);
  ///   a backend timing out degrades to "partial results" badge, never
  ///   fails the whole search.
  Stream<UnifiedApp> search(String query);

  /// Installed apps across all backends, merged.
  Future<List<UnifiedApp>> installed();

  /// Update check across backends — staggered, background, cached (TTL 6h).
  /// MUST NOT run on the UI critical path at startup.
  Future<List<UpdateInfo>> checkUpdates();
}
```

Ranking (v1, deterministic, explainable): installed first → exact name
match → rating → backend preference order (flag: `catalog.backend_order`).
No black-box ML ranking in v1 — explainability is a feature.

## 5. `OperationEngine` (host)

```dart
abstract class OperationEngine {
  /// Enqueue install/remove/update. One active operation per AppIdentity —
  /// a second enqueue for the same app returns the EXISTING handle
  /// (no duplicate downloads, no double polkit prompts).
  Future<OperationHandle> enqueue(OperationKind kind, AppIdentity app);

  /// All non-terminal handles, for the Manage page.
  Stream<List<OperationHandle>> activeOperations();

  /// Coalesce polkit: batch N queued ops into one auth prompt where
  /// the vehicle allows. Never prompt twice for one user gesture.
  Future<void> authenticateBatch(List<OperationHandle> ops);
}
```

## 6. `FeatureFlags` (host)

```dart
abstract class FeatureFlags {
  /// e.g. 'backend.flatpak.enabled', 'catalog.dedupe', 'policy.permissions_prompt'
  bool isEnabled(String key);

  /// Why — for Settings → Backends ("off: killed by flag", "off: flatpak not found").
  FlagState flagState(String key);

  /// Live updates; UI rebuilds when flags change.
  Stream<String> get onChanged;
}
```

Layers (later wins): compiled default → `~/.config/onestore/flags.yaml` →
env `ONESTORE_FLAG_<UPPER_SNAKE>` → remote (opt-in, never required,
never blocks startup). Unknown keys are ignored, never crash.

Reserved namespace: `backend.<id>.enabled` is the per-backend kill switch.
`experimental.*` gates anything half-baked.

## 7. Error taxonomy

**The full taxonomy lives in [`operation-state-machine.md`](operation-state-machine.md)
§7 — twelve typed exceptions, each with a stable `code`, `debugDetail`, and a
structured `Remediation` (retry / freeSpace / checkNetwork / fixBackend /
reportBug / none). Sketch:**

```dart
sealed class StoreException implements Exception {
  String get code;           // 'network', 'auth_denied', 'disk_full', …
  String get debugDetail;    // for logs, never shown raw to users
  Remediation get remediation; // structured next step — not a string
}
```

Rules: every backend maps its native errors into this taxonomy. `failed`
states carry these; the host renders localized messages + actions
(Retry for network, Open Settings for disk full, nothing for auth-denied
beyond a quiet note). Telemetry counts by `code`, never by message text.

## 8. Package layout (melos)

```
packages/
  store_contracts/     # §1–§3, §7. Zero dependencies besides meta/freezed.
                       # THE law. Versioned (see §10).
  store_host/          # §4–§6: catalog, engine, flags, policy, metadata.
                       # Depends only on store_contracts.
  backend_snap/        # implements StoreBackend over snapd.
  backend_deb/         # implements StoreBackend over PackageKit/apt.
  backend_flatpak/     # implements StoreBackend over flatpak.
  app_center/          # UI shell. Depends on store_contracts + store_host.
                       # MUST NOT depend on backend_* (enforced by CI import lint).
```

Repo scripts enforce the dependency arrows with an import linter (local first;
GitHub CI last): if `app_center` imports `backend_snap`, the build fails.
Architecture as code, not as wiki.

## 9. Contract tests — the backend exam

`store_contracts` ships a test suite every backend package MUST pass:

- `search` returns within timeout, stream cancellable, ids unique.
- State-machine assertions — see
  [`operation-state-machine.md`](operation-state-machine.md) §11: legal DAG
  paths, cancel-from-every-phase, progress monotonicity, typed `failed`
  errors, double-enqueue dedup, terminal silence, idempotent no-op,
  `restoring` for re-attached handles.
- Unknown id → `AppNotFoundException`, not a crash.
- All thrown errors are `StoreException` subtypes.
- `isAvailable()` < 200ms, no side effects, callable twice safely.

A backend that fails the exam doesn't ship. The exam is the moat around
the architecture.

## 10. Interface versioning

`store_contracts` is versioned SemVer. Additive changes (new capability,
new optional method with default) = minor. Breaking changes = major, and
backends declare `contractVersion` they implement; the host refuses to load
mismatched majors with a clear log line. We evolve the law deliberately —
a plugin ecosystem dies on silent breakage.

---

*Strong contracts are what let strangers (and future us) write backends
without reading the host source. If a backend author needs to ask "how does
the host call this?" — the contract failed, fix the contract.*
