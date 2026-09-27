# LLD: RPM backend

Companion to `rpm-backend-hld.md`. Concrete types, algorithms, and
error mapping for `packages/backend_rpm`.

## 1. File layout

```
packages/backend_rpm/
  pubspec.yaml                  # name: backend_rpm, 0.1.0
                                # deps: store_contracts (path),
                                #   packagekit ^0.2.7 (D-Bus only —
                                #   IDs parsed at the seam, never via
                                #   the client's strict fromString)
                                # dev_deps: test ^1.25.0
  lib/backend_rpm.dart           # barrel: exports backend.dart, identity.dart
  lib/testing.dart               # StubRpmTransport (NOT in barrel)
  lib/src/transport.dart        # RpmTransport (abstract) + RpmPackageId,
                                #   RpmPackageData, RpmTxStatus,
                                #   RpmTxEvent/RpmTxProgress/RpmTxDone,
                                #   RpmTransaction, RpmTransportException,
                                #   RpmNotFoundException
  lib/src/packagekit_transport.dart  # RealRpmPackageKitTransport
  lib/src/identity.dart         # parsePackageId, cardKey, display helpers
  lib/src/metadata.dart         # version display, summary fallbacks
  lib/src/handle.dart           # RpmOperationHandle
  lib/src/backend.dart          # BackendRpm
  test/exam_test.dart           # contract exam + unit tests (26 tests)
```

## 2. Transport API (exact)

```dart
/// Tolerant PackageKit package-id: `name;evr;arch;origin;data`.
/// The 5-token dnf5 wire shape. `evr` is opaque — carried verbatim,
/// never split (epoch 0 is omitted by the backend; research §1.2).
class RpmPackageId {
  const RpmPackageId({
    required this.name,
    required this.evr,
    required this.arch,
    required this.origin,
    required this.data,
  });

  final String name;
  final String evr;    // opaque
  final String arch;
  final String origin;
  final String data;   // 'installed' for installed packages, else ''

  bool get isInstalled => data == 'installed';

  /// The UI card key: multi-arch packages are separate cards.
  String get cardKey => '$name.$arch';

  /// Throws [FormatException] unless exactly 5 tokens. Never invents
  /// missing fields; never touches the EVR.
  factory RpmPackageId.parse(String raw) {
    final t = raw.split(';');
    if (t.length != 5 || t[0].isEmpty || t[2].isEmpty) {
      throw FormatException('not a 5-token rpm package id: $raw');
    }
    return RpmPackageId(name: t[0], evr: t[1], arch: t[2],
        origin: t[3], data: t[4]);
  }

  /// Verbatim round-trip: what the daemon emitted is what we send back.
  @override
  String toString() => '$name;$evr;$arch;$origin;$data';
}

/// Transport-level failure. The backend maps these to [StoreException];
/// they never escape the backend directly.
class RpmTransportException implements Exception {
  RpmTransportException(this.message);
  final String message;
  @override
  String toString() => 'rpm packagekit: $message';
}

/// The requested package does not exist.
class RpmNotFoundException extends RpmTransportException {
  RpmNotFoundException(super.message);
}

/// Transport-level rpm package snapshot.
class RpmPackageData {
  const RpmPackageData({
    required this.id,          // verbatim package-id (nativeId)
    required this.name,
    required this.arch,
    required this.evr,         // opaque; display only
    required this.summary,
    this.description = '',
    this.license = '',
    this.homepage = '',
    this.installSize = 0,
    this.installed = false,
    this.installedEvr,         // set on update entries (fromVersion)
  });

  final String id;
  final String name;
  final String arch;
  final String evr;
  final String summary;
  final String description;
  final String license;
  final String homepage;
  final int installSize;
  final bool installed;
  final String? installedEvr;
}

/// Coarse transaction phase, in plain Dart (mirrors deb).
enum RpmTxStatus { unknown, download, install, remove, update, verifying, other }

enum RpmTxOutcome { success, cancelled, failed }

sealed class RpmTxEvent {
  const RpmTxEvent();
}

final class RpmTxProgress extends RpmTxEvent {
  const RpmTxProgress({required this.status, required this.percentage});
  final RpmTxStatus status;
  final int percentage;   // 0..100 as reported by PackageKit
}

final class RpmTxDone extends RpmTxEvent {
  const RpmTxDone({required this.outcome,
    this.errorCode = '', this.errorDetails = ''});
  final RpmTxOutcome outcome;
  final String errorCode;     // raw PackageKit error name
  final String errorDetails;
}

/// A live PackageKit transaction, transport-side.
class RpmTransaction {
  RpmTransaction({required this.events,
    required Future<void> Function() cancel}) : _cancel = cancel;

  /// Progress events, then exactly one [RpmTxDone].
  final Stream<RpmTxEvent> events;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

abstract class RpmTransport {
  /// Throw [RpmTransportException] when the daemon is unreachable.
  Future<void> checkAvailable();

  /// One SearchNames transaction with the arch filter
  /// (native arch + noarch). Returns one entry per (name, arch).
  Future<List<RpmPackageData>> search(String query);

  /// Resolve (name, arch) fresh, then one GetDetails transaction.
  /// Throw [RpmNotFoundException] for unknown packages.
  Future<RpmPackageData> getDetails(String packageId);

  /// Verbatim package-ids of installed packages (legacy path).
  Future<List<String>> installedIds();

  /// Bulk installed snapshot: GetPackages({installed}) + one batched
  /// GetDetails, deduped by (name, arch). Throw
  /// [RpmTransportException] when the batch fails; the backend falls
  /// back to the per-package path.
  Future<List<RpmPackageData>> installedPackages();

  /// One GetUpdates transaction. Each entry's [RpmPackageData.id] is
  /// the *update* package-id; [installedEvr] carries the installed
  /// EVR for fromVersion.
  Future<List<RpmPackageData>> updatesAvailable();

  /// Starts the install; the returned transaction's event stream
  /// drives the operation handle. Re-resolves (name, arch) at mutate
  /// time (origin shifts between query and transaction).
  Future<RpmTransaction> install(String packageId);

  Future<RpmTransaction> remove(String packageId);

  Future<RpmTransaction> update(String packageId);
}
```

`RealRpmPackageKitTransport` implements this over `package:packagekit`
for the D-Bus plumbing only: it reads raw package-id strings from
`PackageKitPackageEvent`/`PackageKitDetailsEvent` and parses them with
`RpmPackageId.parse` — it never calls the client's strict 4-token
`fromString`. Details-dict fields read: `package-id`, `summary`,
`description`, `license`, `url`, `size` (install size). `download-size`
is wire-present but unsurfed in MVP (HLD §7).

## 3. listInstalled algorithm

```
tx1 = GetPackages(filter: {installed})            // NO arch filter:
                                                  // installed i686 must list
events = collect Package events until Finished    // (info, id, summary)
ids = [parse(e.id) for e in events]               // 5-token parse; skip garbage
                                                  // (never fail the whole list)
try:
  tx2 = GetDetails(ids.map(toString))             // ONE batched transaction
  detailsByCardKey = {d.cardKey: d for d in tx2}
except RpmTransportException:
  → legacy path (§3.1)
merged = [mergeInstalled(e, detailsByCardKey[e.cardKey]) for e in ids]
dedupe by cardKey = (name, arch)                  // multi-arch = separate cards
```

Merge rule per (name, arch) group: prefer the `installed` event's
EVR; summary prefers the Details summary, falls back to the Package
event summary. `installedVersion` = installed EVR (opaque string).

### 3.1 Legacy fallback (per-package)

`installedIds()` → for each id: `getDetails(id)`; skip on
`RpmNotFoundException` (removed between the two calls); any other
`RpmTransportException` → mapped and thrown (host contract: partial
results only from the bulk path's degradation, the legacy path's
failure is a real error — same split as the deb backend).

## 4. Identity

- `nativeId` = verbatim package-id (`name;evr;arch;origin`).
  The backend treats it as an opaque string; only the transport
  parses it (for name/arch at mutate time).
- `AppInfo`:
  ```dart
  AppInfo(
    identity: AppIdentity(backendId: 'rpm', nativeId: p.id),
    name: p.name,
    summary: p.summary,
    iconUrl: '',                        // no icons on the D-Bus surface
    source: AppSource.rpm,               // NEVER deb (HLD §5)
    version: p.evr.isEmpty ? null : p.evr,
    installedVersion: p.installed ? (p.installedEvr ?? p.evr) : null,
  )
  ```
- Display: name shown bare; arch disambiguated in the card subtitle
  when a sibling arch exists (`firefox · x86_64`). EVR shown
  verbatim as the version string — never prettified (epoch-0 omission
  makes "prettifying" lossy).

## 5. Search

```dart
Stream<AppInfo> search(String query) {
  // 1..200 chars (contract PRE).
  final results = await transport.search(query);   // SearchNames + arch filter
  for (final p in results) {
    if (cancelled || controller.isClosed) break;
    controller.add(_toAppInfo(p));                 // one card per (name, arch)
  }
}
```

`SearchNames` is one transaction; cancelling the subscription
abandons it — the honest bound of "stop work" (same as deb).
`SearchDetails` (description/summary matching) is available on the
transport for a future relevance pass; MVP uses `SearchNames` only.

## 6. getDetails

1. `RpmPackageId.parse(id.nativeId)` → `RpmNotFoundException`-as-
   `AppNotFoundException` on `FormatException` (a corrupt stored id
   is "not found", never a crash).
2. `transport.getDetails(nativeId)` → re-resolves (name, arch),
   one `GetDetails` transaction.
3. Map to `AppDetails`:
   ```dart
   AppDetails(
     app: _toAppInfo(p),
     description: p.description.isEmpty
         ? '${p.summary}\n\n$unsandboxedDisclosure' : '${p.description}\n\n$unsandboxedDisclosure',
     permissions: _rpmPermissions,   // confinement-none, same as deb
     license: p.license.isEmpty ? null : p.license,
     homepage: p.homepage.isEmpty ? null : p.homepage,
   )
   ```
   `_rpmPermissions` = `[Permission(id: 'confinement-none', label:
   'Unsandboxed — full system access')]` — RPMs are unsandboxed;
   say it up front (ADR-009, same as deb).
4. Install size surfaced where the UI wants it (`AppDetails` has no
   size field in the current contract — LLD notes the gap; the data
   is kept on `RpmPackageData.installSize` for the future field).

## 7. Error mapping

| Transport failure | StoreException |
|---|---|
| daemon unreachable / D-Bus `service unknown` | `BackendUnavailableException` |
| `RpmNotFoundException`, `packageNotFound`, `packageNotInstalled`, `no such package` | `AppNotFoundException` |
| `noSpaceOnDevice`, `no space`, `disk full` | `DiskSpaceException` |
| `noNetwork`, `network`, `timeout` | `NetworkException` |
| polkit `not authorized`, `access denied`, `auth` failures | `PermissionException` (neededAccess: 'packagekit system action access (polkit)') |
| 5-token parse failure on a daemon-emitted id | `UnknownStoreException` (wire-shape drift — bug-report generator) |
| anything else | `UnknownStoreException(debugDetail, rawOutput)` |

Raw transport exceptions never escape the backend. Cancel-then-fail
races resolve to `Cancelled`, never `Failed` (operation-state-machine
§3).

## 8. Install / remove / update state machines

Shared handle machinery with the deb backend (`RpmOperationHandle`
mirrors `DebOperationHandle`):

- Phase mapping: `download*` → `Downloading(bytesDone: percentage,
  bytesTotal: 100)` (percentage normalized onto a 0..100 byte scale —
  monotonic, bounded, never fabricated); `install`/`remove`/`update`
  → `Applying`; `signatureCheck` → `Verifying`; anything else in
  flight → `Preparing` (never a DAG-illegal emission — hold the
  current phase instead of lying).
- `cancel()`: prompt `cancelling` ack within 2s; the D-Bus
  transaction's `Finished` event resolves the honest outcome
  (`cancelled` → `Cancelled`; success past the point of no return →
  `Done(cancelRequested: true)`).
- 60s heartbeat re-emit during `downloading`/`applying`
  (`PhaseHeartbeat`; stall-watchdog.md §1).
- `install` on an installed (name, arch) → `Done(noop: true)` —
  checked via `installedIds()` before starting the transaction.
- `remove` on a not-installed id → the daemon reports
  `packageNotInstalled` → `AppNotFoundException`… **or** `Done(noop:
  true)`? Contract §6 prefers noop when cheaply detectable: the
  backend checks `installedIds()` first and returns `Done(noop:
  true)` without a transaction.
- `update` with nothing to update → daemon-side no-op; map the
  daemon's empty/success outcome to `Done(noop: true)`.

**Privilege path (research §6):** install/remove transactions will
hit the polkit prompt → the handle emits `Authenticating` while the
prompt is in flight (the D-Bus call blocks; the state machine has the
phase for exactly this). Update transactions typically skip it
(`system-update` = `allow_active: yes` on stock Fedora).

`checkUpdates()`:

```dart
final updates = await transport.updatesAvailable();
return [
  for (final p in updates)
    UpdateInfo(
      identity: AppIdentity(backendId: 'rpm', nativeId: p.id),
      name: p.name,
      fromVersion: p.installedEvr,
      toVersion: p.evr.isEmpty ? null : p.evr,
    ),
];
```

`recoverInFlight()` → `[]` (HLD §3 — honest; the exam tolerates
empty).

## 9. Exam fixture plan (26 tests)

`StubRpmTransport`: scripted PackageKit-shaped fixtures with
**5-token IDs** (`firefox;135.0-1.fc42;x86_64;updates;installed`).
Fixtures:

- `installedIds` → [`firefox;…;x86_64;updates;installed`,
  `glibc;2.39-2.fc42;i686;fedora;installed`] — the i686 entry proves
  multi-arch cards stay separate.
- `searchScript`: `firefox` x86_64 + i686 candidates (arch filter
  demonstrably applied by the *real* transport; the stub just serves
  what it's scripted).
- `installTargetId` = `vim;9.1-1.fc42;x86_64;fedora;` (available) →
  install flow; `installedTargetId` = the firefox x86_64 id →
  idempotent `Done(noop: true)`.
- `unknownTargetId` = `nope;1.0-1.fc42;x86_64;fedora;` → typed
  not-found.
- Scripted transactions mirror the deb stub: paced progress scripts
  so the handle and the exam's cancel test observe each phase;
  cancel injects a terminal cancelled event.

Test groups (mirroring the appimage 26-test shape):

1. `rpm backend` (contract exam + capabilities + honest empties +
   listInstalled multi-arch shape + search per-(name,arch) cards +
   install noop + remove noop + unknown id typed) — ~8 tests.
2. `package-id parser` (accepts 5 tokens; rejects 4/6/empty/garbage;
   EVR carried verbatim incl. epoch forms; `cardKey`; verbatim
   round-trip) — ~6 tests.
3. `bulk merge` (prefers installed EVR; Details summary wins over
   Package-event summary; batch failure → legacy path invoked;
   multi-arch dedupe by (name, arch)) — ~4 tests.
4. `arch filter` (search path requests the arch filter; installed
   path does not) — ~2 tests.
5. `error mapping` (not-found / unavailable / disk-full /
   permission / unknown → typed codes) — ~5 tests.
6. `noop semantics` (remove of not-installed → noop without
   transaction) — ~1 test.
