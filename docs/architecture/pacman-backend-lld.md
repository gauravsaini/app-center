# LLD: pacman backend

Companion to `pacman-backend-hld.md`. Concrete types, parsing
algorithms, phase mapping, and error mapping for
`packages/backend_pacman`. All pacman output shapes are the
reconstructed fixtures from `pacman-research.md` §2 — cited, not
live-captured.

## 1. File layout

```
packages/backend_pacman/
  pubspec.yaml                  # name: backend_pacman, 0.1.0
                                # deps: store_contracts (path)
                                # dev_deps: test ^1.25.0
                                # NOTE: no process package — dart:io
                                #   Process is sufficient (flatpak
                                #   precedent); no dbus, no ffi.
  lib/backend_pacman.dart        # barrel: exports backend.dart, identity.dart
  lib/testing.dart               # StubPacmanTransport (NOT in barrel)
  lib/src/transport.dart        # PacmanTransport (abstract) +
                                #   PacmanPackageId, PacmanPackageData,
                                #   PacmanTxPhase, PacmanTxEvent
                                #   (progress/done/auth sub-events),
                                #   PacmanTransaction, PacmanProcess,
                                #   PacmanTransportException,
                                #   PacmanNotFoundException
  lib/src/cli_transport.dart    # CliPacmanTransport (Process.start)
  lib/src/identity.dart         # parsePackageId, cardKey, display helpers
  lib/src/metadata.dart         # size parsing (B/KiB/MiB/GiB), version display
  lib/src/handle.dart           # PacmanOperationHandle
  lib/src/backend.dart          # BackendPacman
  test/exam_test.dart           # contract exam + unit tests (30 tests)
```

## 2. Transport API (exact)

```dart
/// Pacman package id: `name;version;arch;repo` (4 tokens).
/// `version` is opaque — `epoch:pkgver-pkgrel` carried verbatim, never
/// split (research §3). `arch`/`repo` may be empty when the id came
/// from the `pacman -Q` path (no repo column there — HLD §4).
class PacmanPackageId {
  const PacmanPackageId({
    required this.name,
    required this.version,
    required this.arch,
    required this.repo,
  });

  final String name;
  final String version; // opaque
  final String arch;    // '' when unknown
  final String repo;    // '' when unknown

  bool get isInstalled => true; // ids only exist for known packages;
                                 // installed-ness is a backend query.

  /// The UI card key: the name alone. alpm's local db is name-keyed;
  /// Arch multilib renames (lib32-*) instead of multi-arching, so
  /// same-name multi-arch installs cannot exist (research §3).
  String get cardKey => name;

  /// Mutate-time target: `repo/name` pins the repo when known,
  /// bare name otherwise (research D2).
  String get target => repo.isEmpty ? name : '$repo/$name';

  /// Throws [FormatException] unless exactly 4 tokens with a
  /// non-empty name. Never invents missing fields; never touches the
  /// version. `;` cannot appear in any field (pacman name/version/
  /// arch/repo character rules), so the split is unambiguous.
  factory PacmanPackageId.parse(String raw) {
    final t = raw.split(';');
    if (t.length != 4 || t[0].isEmpty) {
      throw FormatException('not a 4-token pacman package id: $raw');
    }
    return PacmanPackageId(
        name: t[0], version: t[1], arch: t[2], repo: t[3]);
  }

  /// Verbatim round-trip: what the transport parsed is what we store.
  @override
  String toString() => '$name;$version;$arch;$repo';
}

/// Transport-level failure. The backend maps these to [StoreException];
/// they never escape the backend directly.
class PacmanTransportException implements Exception {
  PacmanTransportException(this.args, this.exitCode, this.stderr);
  final List<String> args;
  final int exitCode;
  final String stderr;
  @override
  String toString() =>
      'pacman ${args.join(' ')} exited $exitCode: $stderr';
}

/// The requested package does not exist (target not found / was not
/// found). Also used internally for the isInstalled==false signal.
class PacmanNotFoundException extends PacmanTransportException {
  PacmanNotFoundException(super.args, super.exitCode, super.stderr);
}

/// Transport-level package snapshot.
class PacmanPackageData {
  const PacmanPackageData({
    required this.id,          // verbatim package-id (nativeId)
    required this.name,
    required this.version,     // opaque; display only
    required this.arch,
    required this.repo,
    required this.summary,
    this.description = '',
    this.url = '',
    this.license = '',
    this.downloadSize = 0,
    this.installSize = 0,
    this.installed = false,
    this.installedVersion,     // old version on -Qu entries (fromVersion)
  });

  final String id;
  final String name;
  final String version;
  final String arch;
  final String repo;
  final String summary;
  final String description;
  final String url;
  final String license;
  final int downloadSize;
  final int installSize;
  final bool installed;
  final String? installedVersion;
}

/// Coarse transaction phase, in plain Dart (mirrors flatpak/rpm).
enum PacmanTxPhase {
  authenticating, // pkexec prompt in flight (no pacman output yet)
  preparing,      // resolving deps, transaction summary
  downloading,    // :: Retrieving packages... / downloading... lines
  verifying,      // checking keyring / package integrity
  applying,       // (N/M) installing|upgrading|removing / post-tx hooks
}

sealed class PacmanTxEvent {
  const PacmanTxEvent();
}

/// A parsed line advanced the transaction. [bytesTotal] is set once
/// from `Total Download Size:`; [fraction] from `(N/M)` markers.
/// Either may be null — the handle never fabricates (research §2.8).
final class PacmanTxProgress extends PacmanTxEvent {
  const PacmanTxProgress({required this.phase, this.bytesTotal, this.fraction});
  final PacmanTxPhase phase;
  final int? bytesTotal;
  final double? fraction; // 0..1, monotonic per transaction
}

/// Terminal event. [cancelledByUs] disambiguates our SIGTERM/SIGKILL
/// from pacman's own failures (HLD §3 race rule).
final class PacmanTxDone extends PacmanTxEvent {
  const PacmanTxDone({
    required this.exitCode,
    required this.stderr,
    this.cancelledByUs = false,
  });
  final int exitCode;
  final String stderr;
  final bool cancelledByUs;
}

/// A live child process, transport-side. Mirrors flatpak's
/// FlatpakProcess: stdout/stderr line streams, exit code, and
/// SIGTERM→grace→SIGKILL terminate.
abstract class PacmanProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  Future<void> terminate({Duration grace = const Duration(seconds: 2)});
}

class PacmanTransaction {
  PacmanTransaction({required this.events,
    required Future<void> Function() cancel}) : _cancel = cancel;

  /// Progress events, then exactly one [PacmanTxDone].
  final Stream<PacmanTxEvent> events;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

abstract class PacmanTransport {
  /// `pacman --version` within the probe budget. Throw
  /// [PacmanTransportException] when the binary is missing/unusable.
  Future<void> checkAvailable();

  /// Cached: is the `checkupdates` (pacman-contrib) binary present?
  Future<bool> hasCheckupdates();

  /// One `pacman -Ss -- <escaped query>` invocation. The transport
  /// escapes the query to a literal regex (research D12).
  Future<List<PacmanPackageData>> search(String query);

  /// `pacman -Si -- <name>` post-filtered on `Name:`, falling back to
  /// `pacman -Qi -- <name>`. Throw [PacmanNotFoundException] when
  /// neither finds it.
  Future<PacmanPackageData> getDetails(String packageId);

  /// ONE `pacman -Q` invocation, parsed line-wise. Skip unparseable
  /// lines; throw [PacmanTransportException] only when the invocation
  /// itself fails. There is no N+1 legacy path (HLD §3).
  Future<List<PacmanPackageData>> installedPackages();

  /// `pacman -Q -- <name>`: true on exit 0, false on exit 1 with
  /// "was not found". Throw [PacmanTransportException] on any other
  /// failure.
  Future<bool> isInstalled(String name);

  /// `checkupdates` when present (0 → parse, 2 → [], 1 → typed),
  /// else `pacman -Qu` with the exit-1 quirk handled by stdout/stderr
  /// inspection. Each entry's [PacmanPackageData.version] is the NEW
  /// version; [installedVersion] is the OLD (fromVersion).
  Future<List<PacmanPackageData>> updatesAvailable();

  /// Spawn `pkexec pacman -S --needed --noconfirm -- <target>`.
  /// The event stream drives the handle.
  Future<PacmanTransaction> install(String packageId);

  /// Spawn `pkexec pacman -R --noconfirm -- <name>`. MVP is `-R`,
  /// not `-Rs` (HLD §2).
  Future<PacmanTransaction> remove(String packageId);

  /// Spawn `pkexec pacman -S --noconfirm -- <name>` (upgrades an
  /// installed package; the backend noop-checks first via
  /// [updatesAvailable]).
  Future<PacmanTransaction> update(String packageId);
}
```

`CliPacmanTransport` implements this with `Process.start`, line-split
stdout/stderr (mirroring flatpak's `_CliProcess`), and the
`terminate()` SIGTERM→2s→SIGKILL shape. Read invocations
(`--version`, `-Q`, `-Ss`, `-Si`, `-Qi`, `-Qu`, `checkupdates`) run
**without** pkexec (all root-free); only the three mutating spawns go
through `pkexec`. Spawning `pkexec` itself: `Process.start('pkexec',
['pacman', ...])`; a `ProcessException` (binary missing) becomes
`PacmanTransportException(['pkexec', ...], 127, 'pkexec not found:
polkit not installed')` so the backend maps it to
`PermissionException` with the polkit remediation (research §4).

## 3. Parsing algorithms

### 3.1 `pacman -Q` lines → installed entries

```
for line in stdout.split('\n'):
  line = line.trim(); if empty: continue
  i = line.indexOf(' ')
  if i < 0: continue                      // skip, never fail the list
  name = line[0:i]; version = line[i+1:].trim()
  if name.empty or version.empty: continue // skip
  id = PacmanPackageId(name, version, '', '').toString()
  emit PacmanPackageData(id, name, version, arch:'', repo:'',
                         summary:'', installed:true)
```

Summary is `''` by construction — descriptions are a `getDetails()`
concern (HLD §3; the N+1 lesson). `installedVersion` = version.

### 3.2 `pacman -Ss` blocks → search results

```
blocks = split stdout into header + continuation lines:
  headerRe = ^([^/\s]+)/([^\s]+)\s+([^\s]+)(?:\s+\[(.*)\])?$
  for line in stdoutLines:
    m = headerRe.match(line)
    if m: flush current block; current = (repo=m1, name=m2, version=m3,
                                          installed = m4 != null)
    elif line starts with whitespace and current != null:
      current.descriptionLines.add(line.trim())
    else: flush current; ignore line        // never fail the search
for each block:
  id = PacmanPackageId(name, version, arch:'', repo).toString()
      // arch unknown from -Ss; filled by getDetails (-Si)
  emit PacmanPackageData(..., summary: first description line ?? '',
                         description: all lines joined '\n',
                         installed: block.installed)
```

`summary` = first description line (the `-Ss` shape is one logical
description possibly wrapped — first line is the short form).

### 3.3 `-Si`/`-Qi` info blocks → details

```
blocks = stdout.split('\n\n')
for block in blocks:
  fields = {}
  currentKey = null
  for line in block.split('\n'):
    m = ^([^:]+?)\s*:\s*(.*)$ .match(line)
    if m: currentKey = m1.trim(); fields[currentKey] = m2.trim()
    elif line starts with '  ' and currentKey != null:
      fields[currentKey] += '\n' + line.trim()   // continuation
  if fields['Name'] != requestedName: continue    // regex-arg guard
  return PacmanPackageData(
    id: PacmanPackageId(name, fields['Version'] ?? '',
                        fields['Architecture'] ?? '',
                        fields['Repository'] ?? '').toString(),
    summary: fields['Description'] ?? '',
    description: fields['Description'] ?? '',
    url: fields['URL'] ?? '', license: fields['Licenses'] ?? '',
    downloadSize: parseSize(fields['Download Size']),
    installSize: parseSize(fields['Installed Size']),
    installed: fromQi,
  )
throw PacmanNotFoundException if no block matched
```

`parseSize` (metadata.dart): `^([\d.]+)\s*([A-Za-z]+)$` →
`B=1, KiB=1024, MiB=1024², GiB=1024³` (case-insensitive, tux_store
rule); unrecognized → 0 (never throw on a size string).

### 3.4 `pacman -Qu` / `checkupdates` lines → updates

```
quRe = ^([^\s]+)\s+([^\s]+)\s+->\s+([^\s]+)$
for line in stdoutLines:
  line = line.trim()
  if line.contains('[') and line.contains(']'): continue  // [ignored] etc.
  m = quRe.match(line); if !m: continue                   // skip, not fatal
  (name, oldVer, newVer) = m.groups
  id = PacmanPackageId(name, newVer, '', '').toString()
  emit PacmanPackageData(..., version: newVer,
                         installed: true, installedVersion: oldVer)
```

Exit-code handling (research §2.5–2.6):

```
code = await exitCode
if using checkupdates:
  0 → parse lines; 2 → []; 1 → typed error from stderr
else: // pacman -Qu
  0 → parse lines
  1 → stdout.isEmpty ? [] : parse lines   // 1+empty = no updates (normal)
  _ → typed error from stderr
```

## 4. Identity

- `nativeId` = verbatim `name;version;arch;repo`. The backend treats
  it as opaque; only the transport parses it (for `target` at mutate
  time).
- Card key = **name** (`PacmanPackageId.cardKey`) — no multi-arch
  cards (research §3; deliberate divergence from rpm).
- `AppInfo`:
  ```dart
  AppInfo(
    identity: AppIdentity(backendId: 'pacman', nativeId: p.id),
    name: p.name,
    summary: p.summary,
    iconUrl: '',                        // no icons in pacman's CLI surface
    source: AppSource.pacman,           // NEVER deb (HLD §5)
    version: p.version.isEmpty ? null : p.version,
    installedVersion: p.installed
        ? (p.installedVersion ?? p.version) : null,
  )
  ```
- Display: version shown verbatim (epoch prefix included) — never
  prettified.

## 5. Progress line → phase mapping (transport)

The mutating spawn's stdout lines are classified in order; the first
match wins. Classification is regex-tolerant (fixtures are
reconstructed — the classifier must not depend on exact spacing):

| Line pattern | Event |
|---|---|
| `Total Download Size:\s*([\d.]+\s*[KMGT]?i?B)` | `PacmanTxProgress(preparing, bytesTotal: parseSize(m1))` — the summary line also keeps the phase at preparing; bytesTotal is latched for the download phase |
| `^:: Retrieving packages` | `downloading` |
| ` downloading\.\.\.$` (per-file) | `downloading` (liveness; no byte math — research §2.8) |
| `^checking keyring`, `^checking package integrity` | `verifying` |
| `^:: Processing package changes`, `^:: Running post-transaction hooks` | `applying` (fraction null unless `(N/M)` seen) |
| `^\((\d+)/(\d+)\)\s+(installing\|upgrading\|removing\|checking)` | `applying(fraction: n/m)` — monotonic per transaction |
| `^resolving dependencies`, `^looking for conflicting`, `^Packages \(\d+\)` | `preparing` |
| anything else | no event (still counts as liveness — see below) |

Liveness rule: **every** stdout/stderr line (even unclassified) resets
the stall watchdog's timer via the handle's emission path — the handle
calls `_heartbeat.markEmitted()` on each `_emit`, and the transport
emits a `PacmanTxProgress` with the *current* phase (no phase change)
when 60s pass without a classified line? No — simpler and honest: the
handle's `PhaseHeartbeat` (60s, stall-watchdog.md §1) re-emits the
current phase; the transport additionally emits a progress event per
line so `markEmitted()` fires on real output. The heartbeat timer is
the backstop; line events are the primary signal. Both are legal
self-transitions (operation-state-machine.md §2).

Phase → `OperationState` in the handle:

```
authenticating → Authenticating   // emitted once at spawn, before output
preparing      → Preparing
downloading    → Downloading(bytesDone: 0, bytesTotal: latched-or-null)
verifying      → Verifying
applying       → Applying(fraction: fraction-or-null)
```

`bytesDone` stays 0 through download (no honest per-byte source —
research §2.8); the state is still useful (`bytesTotal` known,
indeterminate bar + heartbeat). `fraction` from `(N/M)` is real and
monotonic. Anything the DAG forbids is held, never emitted (rpm
handle's `_emitState` discipline).

pkexec exit codes (transport → handle):

- `126` → `Failed(AuthException(debugDetail: 'polkit dialog
  dismissed', kind: AuthKind.dismissed, backendId: 'pacman'))` —
  remediation `none` (quiet).
- `127` → `Failed(PermissionException(debugDetail: stderr,
  neededAccess: 'polkit authorization for pacman', backendId:
  'pacman'))`.
- other non-zero → error-table mapping (§7) on the collected stderr.
- `cancelledByUs` (we sent SIGTERM/SIGKILL) → `Cancelled`
  unconditionally — the §3 race rule; even if pacman printed errors
  while dying, the user's cancel wins.
- exit 0 after cancel requested → `Done(cancelRequested: true)`
  (pacman committed before the signal landed; pacman does not roll
  back — research §8).

## 6. getDetails / search / noop checks (backend)

```dart
Future<AppDetails> getDetails(AppIdentity id) async {
  PacmanPackageId pid;
  try { pid = parsePackageId(id.nativeId); }
  on FormatException catch (e) {
    throw AppNotFoundException(
        debugDetail: 'corrupt pacman package id: $e', backendId: 'pacman');
  }
  late final PacmanPackageData p;
  try { p = await transport.getDetails(id.nativeId); }
  on PacmanNotFoundException catch (e) {
    throw AppNotFoundException(debugDetail: e.stderr, backendId: 'pacman');
  } on PacmanTransportException catch (e) { throw _mapError(e); }
  return AppDetails(
    app: _toAppInfo(p),
    description:
      '${p.description.isEmpty ? p.summary : p.description}\n\n$unsandboxedDisclosure',
    permissions: _pacmanPermissions,
    license: p.license.isEmpty ? null : p.license,
    homepage: p.url.isEmpty ? null : p.url,
  );
}
```

`_pacmanPermissions` = `[Permission(id: 'confinement-none', label:
'Unsandboxed — full system access')]`; `unsandboxedDisclosure` =
`'Pacman packages run unsandboxed with full system access.'`
(ADR-009, same as deb/rpm).

Noop checks (contract §6 prefers cheap noop):

- `install`: `await transport.isInstalled(pid.name)` → true →
  `Done(noop: true)` (plus `--needed` on the child as belt-and-braces).
- `remove`: `isInstalled` false → `Done(noop: true)`.
- `update`: `final updates = await transport.updatesAvailable();
  if (!updates.any((u) => u.name == pid.name)) → Done(noop: true)`.
  (One fakeroot sync per update call when `checkupdates` is present —
  HLD §7 records the cost honestly.)

`search(query)` streams `transport.search()` results; the
subscription's `onCancel` kills the child (500ms rule).

## 7. Error mapping

Patterns match against `stderr.toLowerCase()` unless noted. Raw
transport exceptions never escape the backend.

| Signal | StoreException |
|---|---|
| `Process.start` throws (binary missing) → exit 127, `pacman not found` | `BackendUnavailableException` (read path) |
| `pkexec` missing → exit 127, `pkexec not found` | `PermissionException(neededAccess: 'polkit (pkexec) for privileged pacman operations — install polkit and use a session with an authentication agent', remediation: fixBackend)` |
| pkexec exit 126 | `AuthException(kind: dismissed)` — quiet, remediation `none` |
| pkexec exit 127 (auth not obtained / error) | `PermissionException(neededAccess: 'polkit authorization for pacman', debugDetail: stderr)` |
| `you cannot perform this operation unless you are root` | `PermissionException(neededAccess: 'root via pkexec (polkit)')` — defense-in-depth; should not happen when pkexec worked |
| `target not found:` | `AppNotFoundException` |
| `package '…' was not found` (from `-Q`) | `AppNotFoundException` (or the `isInstalled==false` signal — not an error) |
| `could not satisfy dependencies` | `DependencyException(details: <each '…' line>, remediation: none)` |
| `conflicting files` | `ConflictException(debugDetail: …)` |
| `unable to lock database` / `could not lock database` | `ConflictException(debugDetail: 'pacman db locked by another process')` — retryable manually, not auto |
| `failed retrieving file` / `failed to synchronize` / `could not resolve host` | `NetworkException` |
| `partition .* too full` / `not enough .* disk space` | `DiskSpaceException(neededBytes: -1, availableBytes: 0)` — pacman does not report byte counts here (rpm precedent) |
| `signature .* is invalid` / `invalid or corrupted package` | `VerificationException(remediation: retry)` |
| `checkupdates` exit 1 (`cannot fetch updates`) | `NetworkException` when stderr mentions fetch/download/host, else `UnknownStoreException` |
| ID parse failure on a transport-emitted id | `UnknownStoreException` (wire-shape drift — bug-report generator) |
| anything else | `UnknownStoreException(debugDetail, backendId: 'pacman')` |

Cancel-then-fail races resolve to `Cancelled`, never `Failed`
(operation-state-machine.md §3; LLD §5).

## 8. Install / remove / update state machines

Shared handle machinery with the flatpak backend
(`PacmanOperationHandle` mirrors `FlatpakOperationHandle`'s
CLI-child discipline; the rpm handle's `_emitState` DAG guard and
`PhaseHeartbeat` are reused as-is):

- Spawn → emit `Authenticating` immediately (pkexec prompt in flight —
  research §4). First classified pacman line → `Preparing` (DAG-legal
  `authenticating → preparing`).
- Progress events map per §5; unclassified lines still pulse liveness.
- `cancel()`: prompt `cancelling` ack within 2s (operation-state-machine
  §3), then `transaction.cancel()` → child `terminate()` (SIGTERM,
  2s grace, SIGKILL — flatpak's `_CliProcess.terminate` shape). The
  terminal state follows the child's `PacmanTxDone` per §5's exit-code
  rules.
- 60s heartbeat re-emit during `downloading`/`applying`
  (`PhaseHeartbeat`; stall-watchdog.md §1). The engine's 10-min stall
  watchdog applies unchanged; `authenticating` is already excluded
  from watched phases (user-attended prompt — operation-state-machine
  §4), which is exactly right for the polkit dialog.
- `install` on installed → `Done(noop: true)` (checked via
  `isInstalled()` before spawn; `--needed` as backup).
- `remove` on not-installed → `Done(noop: true)` without a child.
- `update` with the name absent from `updatesAvailable()` →
  `Done(noop: true)` without a child.
- `checkUpdates()` maps `updatesAvailable()` entries to `UpdateInfo`
  (`fromVersion: installedVersion`, `toVersion: version`).
- `recoverInFlight()` → `[]` (HLD §3).

**Non-atomicity note for the implementer:** after `SIGKILL`
mid-apply, the local db may record a half-configured package. The
handle reports `Cancelled` (the user's request was honored — the
process is dead); it must NOT report `Done`. The next `pacman -Su`
repairs the system. This is documented in the handle's doc comment so
no future reader "fixes" it into a lie.

## 9. Exam fixture plan (30 tests)

`StubPacmanTransport`: scripted fixtures taken verbatim from
research §2 (the `firefox`/`nginx`/`glibc`/`docker` shapes). Fixtures:

- `installedLines`: the §2.1 block incl. the epoch-prefixed
  `docker 1:28.5.1-1` line (version opacity proof).
- `searchScript`: the §2.2 block incl. the wrapped-description
  `firefox-i18n-de` entry and the `[installed]` flag.
- `siNginx`: the §2.3 block; `qiYay`: a `-Qi` block without
  `Repository`/`Download Size` (fallback proof).
- `quLines`: the §2.5 block.
- `installScript`: the §2.7 transaction lines, paced so the handle
  test observes preparing → downloading → verifying → applying.
- `pkexecDismissed` → exit 126; `pkexecDenied` → exit 127 with
  `Error executing command as another user: Not authorized`.

Test groups:

1. `pacman backend` (contract exam + capabilities + honest empties +
   listInstalled shape + search cards + install noop + remove noop +
   update noop-via-empty-updates + unknown id typed +
   recoverInFlight `[]`) — ~10 tests.
2. `package-id parser` (accepts 4 tokens; rejects 3/5/empty/garbage;
   version verbatim incl. `1:28.5.1-1`; `target` with/without repo;
   verbatim round-trip; cardKey == name) — ~7 tests.
3. `output parsers` (`-Q` split-on-first-space + skip-garbage;
   `-Ss` header regex + continuation join + `[installed]` flag;
   `-Si` field map + continuation lines + `Name:` post-filter;
   `-Qu` `old -> new` + `[...]` drop; `parseSize` B/KiB/MiB/GiB +
   garbage→0) — ~7 tests.
4. `checkupdates vs -Qu` (exit 2 → `[]`; exit 1 → typed; `-Qu` exit 1
   + empty stdout → `[]`; `-Qu` exit 1 + stderr → typed) — ~4 tests.
5. `error mapping` (rootless stderr → PermissionException; 126 →
   AuthException(dismissed); 127 → PermissionException; target-not-found
   → AppNotFound; db-lock → ConflictException; corrupt id → typed)
   — ~6 tests.
6. `cancel semantics` (cancel during applying → `cancelling` ≤2s →
   `cancelled`, never `failed`; kill-after-commit → `done`
   with `cancelRequested: true`) — ~2 tests.

Count check: 10+7+7+4+6+2 = 36 — trim to 30 by folding (exam already
covers noop/cancel basics; keep the listed groups, drop the weakest
duplicates at implementation time. The number is a plan, not a
promise — the exam's assertions are.)

## 10. Platform seeding edit (exact)

In `packages/store_host/lib/src/platform_detection.dart`,
`seedPlatformBackendDefaults` gains one branch (research D11):

```dart
void seedPlatformBackendDefaults(MapFeatureFlags flags, PlatformInfo platform) {
  if (platform.isFedoraLike || platform.isArchLike) {
    flags.seedDefault('backend.snap.enabled', false);
    flags.seedDefault('backend.deb.enabled', false);
  }
  // NEW: pacman is unambiguous on Arch-like systems (the probe is
  // `pacman --version`, which only passes where pacman exists), so —
  // unlike backend.rpm (seeding deferred, research D11) — it is
  // seeded ON here. User setFlag still wins (seeded-defaults layer).
  if (platform.isArchLike) {
    flags.seedDefault('backend.pacman.enabled', true);
  }
}
```

Plus `flags.dart`: `'backend.pacman.enabled': false` with the ADR-010
owner/removal-date comment. And `store_host_wiring.dart`: register
`BackendPacman(transport: CliPacmanTransport())` in the composition
root. `AppSource.pacman` in `store_contracts/.../identity.dart`.
All four edits belong to the implementation leaf, listed here so the
slice is complete.
