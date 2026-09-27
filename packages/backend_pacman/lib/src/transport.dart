/// [PacmanTransport]: everything the pacman backend needs from the
/// outside world, expressed in plain Dart. [CliPacmanTransport]
/// implements it over the `pacman(1)` CLI subprocess; tests script
/// [StubPacmanTransport] (in `lib/testing.dart`).
///
/// Package-id parsing happens HERE, at the seam — never above the
/// transport layer. The version is opaque end-to-end: carried
/// verbatim, never split (research §3).
library;

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

  /// Opaque `epoch:pkgver-pkgrel`. Never parsed or rebuilt.
  final String version;

  /// '' when unknown (the `-Q` path emits no arch column).
  final String arch;

  /// '' when unknown (the `-Q` path emits no repo column).
  final String repo;

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
    return PacmanPackageId(name: t[0], version: t[1], arch: t[2], repo: t[3]);
  }

  /// Verbatim round-trip: what the transport parsed is what we store.
  @override
  String toString() => '$name;$version;$arch;$repo';
}

/// Transport-level failure. The backend maps these to [StoreException]
/// subtypes; they never escape the backend directly.
class PacmanTransportException implements Exception {
  PacmanTransportException(this.args, this.exitCode, this.stderr);

  final List<String> args;
  final int exitCode;
  final String stderr;

  @override
  String toString() => 'pacman ${args.join(' ')} exited $exitCode: $stderr';
}

/// The requested package does not exist (target not found / was not
/// found). Also used internally for the isInstalled==false signal.
class PacmanNotFoundException extends PacmanTransportException {
  PacmanNotFoundException(super.args, super.exitCode, super.stderr);
}

/// Transport-level package snapshot.
class PacmanPackageData {
  const PacmanPackageData({
    required this.id,
    required this.name,
    required this.version,
    required this.arch,
    required this.repo,
    required this.summary,
    this.description = '',
    this.url = '',
    this.license = '',
    this.downloadSize = 0,
    this.installSize = 0,
    this.installed = false,
    this.installedVersion,
  });

  /// Verbatim package-id (the backend's nativeId).
  final String id;
  final String name;

  /// Opaque; display only.
  final String version;
  final String arch;
  final String repo;
  final String summary;
  final String description;
  final String url;
  final String license;

  /// Bytes, from `-Si`'s `Download Size` / `Installed Size`.
  final int downloadSize;
  final int installSize;
  final bool installed;

  /// Set on update entries: the old version (fromVersion).
  final String? installedVersion;
}

/// Coarse transaction phase, in plain Dart (mirrors flatpak/rpm).
enum PacmanTxPhase {
  /// pkexec prompt in flight (no pacman output yet).
  authenticating,

  /// Resolving deps, transaction summary.
  preparing,

  /// `:: Retrieving packages...` / ` downloading...` lines.
  downloading,

  /// Checking keyring / package integrity.
  verifying,

  /// `(N/M) installing|upgrading|removing` / post-tx hooks.
  applying,
}

/// Base of the transport-level transaction event stream.
sealed class PacmanTxEvent {
  const PacmanTxEvent();
}

/// A parsed line advanced the transaction. [bytesTotal] is set once
/// from `Total Download Size:`; [fraction] from `(N/M)` markers.
/// Either may be null — the transport never fabricates (research §2.8).
/// A progress event that carries no new information (unclassified
/// line, same phase) is a liveness pulse: the handle marks the
/// heartbeat without emitting a visible state change.
final class PacmanTxProgress extends PacmanTxEvent {
  const PacmanTxProgress({required this.phase, this.bytesTotal, this.fraction});

  final PacmanTxPhase phase;
  final int? bytesTotal;

  /// 0..1, monotonic per transaction.
  final double? fraction;
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

  /// SIGTERM, then SIGKILL after [grace].
  Future<void> terminate({Duration grace = const Duration(seconds: 2)});
}

/// A mutating pacman transaction, transport-side.
class PacmanTransaction {
  PacmanTransaction({
    required this.events,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  /// Progress events, then exactly one [PacmanTxDone].
  final Stream<PacmanTxEvent> events;
  final Future<void> Function() _cancel;

  /// Best effort: terminate the child; the event stream resolves the
  /// honest outcome (Cancelled, or Done(cancelRequested) when pacman
  /// committed before the signal landed).
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

  /// Best-effort: terminate the in-flight [search] child, if any.
  /// The base implementation is a no-op; the CLI transport kills the
  /// `pacman -Ss` child so search cancellation stops backend work
  /// within the 500ms contract rule (HLD §3).
  Future<void> cancelSearch() async {}

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
  /// version; [PacmanPackageData.installedVersion] is the OLD
  /// (fromVersion).
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
