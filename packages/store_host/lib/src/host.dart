/// [StoreHost]: the composition point. Implements [UnifiedCatalog] and
/// [OperationEngine] over registered backends.
///
/// Grouping policy (v1): one [UnifiedApp] per [AppInfo] — no
/// cross-backend merging. The product thesis prefers duplicate cards
/// over unsafe merges; smart merging arrives with the community
/// metadata index, not with heuristics here.
library;

import 'dart:async';
import 'dart:io';

import 'package:store_contracts/store_contracts.dart';

import 'check_updates_result.dart';
import 'identity/file_identity_index.dart';
import 'identity/identity_resolver.dart';
import 'identity/seed_index.dart';
import 'installed_result.dart';

/// Creates single-shot [Timer]s. Injected into [StoreHost] so the stall
/// watchdog's clock is testable: production passes a factory returning
/// real timers; tests pass a fake with manual `advance()`. The engine
/// never reads the wall clock — every event re-arms a fresh single-shot
/// timer (docs/architecture/stall-watchdog.md §2).
typedef TimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// Production [TimerFactory]: real one-shot timers.
Timer _realTimerFactory(Duration duration, void Function() callback) =>
    Timer(duration, callback);

/// Injectable wall-clock for the probe cache's lazy TTL expiry.
/// Production passes [DateTime.now]; tests pass a mutable fake.
/// The engine never calls `DateTime.now()` directly.
typedef Clock = DateTime Function();

/// Production [Clock].
DateTime _realClock() => DateTime.now();

/// One memoized `isAvailable()` result. Expiry is evaluated lazily on
/// read against the host's injectable [Clock] — no invalidation timer
/// is ever armed, so a [StoreHost] can never leak pending timers into
/// a test's teardown (or a widget tree's dispose).
class _ProbeCacheEntry {
  _ProbeCacheEntry(this.value, this.cachedAt);

  final bool value;
  final DateTime cachedAt;
}

class StoreHost implements UnifiedCatalog, OperationEngine {
  StoreHost({
    required FeatureFlags flags,
    TimerFactory? timerFactory,
    Clock? clock,
  }) : _flags = flags,
       _timerFactory = timerFactory ?? _realTimerFactory,
       _clock = clock ?? _realClock;

  final FeatureFlags _flags;
  final TimerFactory _timerFactory;
  final Clock _clock;
  final List<StoreBackend> _backends = [];
  final Map<String, OperationHandle> _inflight = {};
  final StreamController<List<OperationHandle>> _activeChanges =
      StreamController<List<OperationHandle>>.broadcast();

  /// Memoized `isAvailable()` results per backend id
  /// (docs/architecture/platform-detection.md §4).
  final Map<String, _ProbeCacheEntry> _probeCache = {};

  /// Lazy Phase 3 identity plumbing (phase3-identity-hld.md). Built on
  /// the first [resolveIdentity] call and cached for the host's
  /// lifetime — slice 1 has no reload API. Never built when
  /// `phase3.identity.enabled` is false.
  IdentityIndex? _identityIndex;
  IdentityResolver? _identityResolver;

  /// Register a backend plugin. Called once at the composition root
  /// (the app's `main.dart`) — never from UI pages.
  void registerBackend(StoreBackend backend) => _backends.add(backend);

  static String _key(AppIdentity id) => '${id.backendId}:${id.nativeId}';

  StoreBackend? _findBackend(String backendId) {
    for (final b in _backends) {
      if (b.id == backendId) return b;
    }
    return null;
  }

  /// Backends that are both flag-enabled and currently available.
  /// A missing backend is a normal runtime condition, not an error.
  Future<List<StoreBackend>> enabledBackends() async {
    final out = <StoreBackend>[];
    for (final b in _backends) {
      if (!_flags.isEnabled('backend.${b.id}.enabled')) continue;
      // Flag-off backends bypass the probe (and the cache) entirely: a
      // seeding change takes effect immediately, never waits out a TTL.
      if (await _isAvailableCached(b)) out.add(b);
    }
    return out;
  }

  /// Memoized `isAvailable()` per backend id
  /// (docs/architecture/platform-detection.md §4). The TTL comes from
  /// the `host.probe_cache_ttl_ms` flag, read at call time; `<= 0`
  /// disables caching entirely (every call probes). A throwing probe
  /// still counts as unavailable.
  ///
  /// Expiry is lazy: entries carry the probe timestamp and are
  /// re-probed on read once older than the TTL. No invalidation timer
  /// is ever armed — expiry never needs to fire proactively (unlike
  /// the stall watchdog), so the cache cannot leak pending timers.
  ///
  /// Why the semantics stay safe: a stale `true` only costs one failed
  /// fetch (the fan-out degrades to partial as before); a stale
  /// `false` excludes the backend for at most the TTL, then the next
  /// call re-probes. Bounded, self-healing.
  Future<bool> _isAvailableCached(StoreBackend backend) async {
    final ttlMs = _flags.getInt('host.probe_cache_ttl_ms');
    if (ttlMs <= 0) {
      try {
        return await backend.isAvailable();
      } catch (_) {
        return false;
      }
    }
    final hit = _probeCache[backend.id];
    if (hit != null &&
        _clock().difference(hit.cachedAt).inMilliseconds < ttlMs) {
      return hit.value;
    }
    bool value;
    try {
      value = await backend.isAvailable();
    } catch (_) {
      value = false;
    }
    _probeCache[backend.id] = _ProbeCacheEntry(value, _clock());
    return value;
  }

  @override
  Stream<UnifiedApp> search(String query) {
    if (query.isEmpty || query.length > 200) {
      throw ArgumentError.value(query, 'query', 'must be 1..200 chars');
    }
    final controller = StreamController<UnifiedApp>();
    var cancelled = false;
    final subs = <StreamSubscription<AppInfo>>[];
    // Cancelling the UI subscription stops backend work.
    controller.onCancel = () async {
      cancelled = true;
      for (final s in subs) {
        await s.cancel();
      }
    };
    () async {
      try {
        final backends = await enabledBackends();
        if (backends.isEmpty || cancelled) {
          await controller.close();
          return;
        }
        var pending = backends.length;
        void finishOne() {
          if (--pending == 0 && !controller.isClosed) controller.close();
        }

        final timeoutMs = _flags.getInt('catalog.search_timeout_ms');
        final timeout = Duration(
          milliseconds: timeoutMs > 0 ? timeoutMs : 5000,
        );
        for (final b in backends) {
          if (cancelled) break;
          try {
            late final StreamSubscription<AppInfo> sub;
            sub = b
                .search(query)
                .timeout(timeout)
                .listen(
                  (app) {
                    if (!cancelled && !controller.isClosed) {
                      controller.add(
                        UnifiedApp(
                          groupId: '${b.id}:${app.identity.nativeId}',
                          variants: [app],
                        ),
                      );
                    }
                  },
                  // A backend failing or stalling degrades to partial
                  // results — it never fails the whole search.
                  onError: (_) => finishOne(),
                  onDone: finishOne,
                );
            subs.add(sub);
          } catch (_) {
            finishOne();
          }
        }
        if (cancelled && !controller.isClosed) await controller.close();
      } catch (_) {
        if (!controller.isClosed) await controller.close();
      }
    }();
    return controller.stream;
  }

  /// Detailed installed listing: parallel fan-out over every enabled
  /// backend with a per-backend timeout
  /// (docs/architecture/parallel-installed.md §1).
  ///
  /// A backend that hangs past the `installed.backend_timeout_ms` budget
  /// (read at call time, never cached) or throws is excluded and named
  /// in [InstalledResult.partialBackendIds] — the listing itself never
  /// throws. Results are reassembled in backend registration order,
  /// never completion order. One [UnifiedApp] per [AppInfo] — no
  /// cross-backend merging (v1 grouping policy, same as search()).
  Future<InstalledResult> installedDetailed() async {
    final timeoutMs = _flags.getInt('installed.backend_timeout_ms');
    final timeout = Duration(milliseconds: timeoutMs > 0 ? timeoutMs : 30000);
    // Flag filter only: isAvailable() runs INSIDE the per-backend
    // budget below (never via enabledBackends()), so a
    // contract-violating hang in isAvailable() can't stall the fan-out
    // before it starts. A missing backend is a normal runtime
    // condition, not an error.
    final backends = [
      for (final b in _backends)
        if (_flags.isEnabled('backend.${b.id}.enabled')) b,
    ];
    // Index slots preserve registration order: completion order is
    // nondeterministic and must never leak into the result list.
    final slots = List<List<AppInfo>?>.filled(backends.length, null);
    await Future.wait([
      for (var i = 0; i < backends.length; i++)
        _installedOneWithTimeout(
          backends[i],
          timeout,
        ).then((r) => slots[i] = r),
    ]);
    final apps = <UnifiedApp>[];
    final partial = <String>[];
    for (var i = 0; i < backends.length; i++) {
      final slot = slots[i];
      if (slot == null) {
        partial.add(backends[i].id);
        continue;
      }
      for (final app in slot) {
        apps.add(
          UnifiedApp(
            groupId: '${backends[i].id}:${app.identity.nativeId}',
            variants: [app],
          ),
        );
      }
    }
    return InstalledResult(apps: apps, partialBackendIds: partial);
  }

  @override
  Future<List<UnifiedApp>> installed() async {
    // Silent partial degradation: partiality details are available
    // via installedDetailed(); this UnifiedCatalog override keeps its
    // signature and never-throws contract.
    return (await installedDetailed()).apps;
  }

  /// Detailed update check: parallel fan-out over every enabled
  /// backend with a per-backend timeout
  /// (docs/architecture/parallel-check-updates.md §1).
  ///
  /// A backend that hangs past the `updates.backend_timeout_ms` budget
  /// (read at call time, never cached) or throws is excluded and named
  /// in [CheckUpdatesResult.partialBackendIds] — the check itself
  /// never throws. Results are reassembled in backend registration
  /// order, never completion order.
  Future<CheckUpdatesResult> checkUpdatesDetailed() async {
    final timeoutMs = _flags.getInt('updates.backend_timeout_ms');
    final timeout = Duration(milliseconds: timeoutMs > 0 ? timeoutMs : 30000);
    // Flag filter only: isAvailable() runs INSIDE the per-backend
    // budget below (never via enabledBackends()), so a
    // contract-violating hang in isAvailable() can't stall the fan-out
    // before it starts. A missing backend is a normal runtime
    // condition, not an error.
    final backends = [
      for (final b in _backends)
        if (_flags.isEnabled('backend.${b.id}.enabled')) b,
    ];
    // Index slots preserve registration order: completion order is
    // nondeterministic and must never leak into the result list.
    final slots = List<List<UpdateInfo>?>.filled(backends.length, null);
    await Future.wait([
      for (var i = 0; i < backends.length; i++)
        _checkOneWithTimeout(backends[i], timeout).then((r) => slots[i] = r),
    ]);
    final updates = <UpdateInfo>[];
    final partial = <String>[];
    for (var i = 0; i < backends.length; i++) {
      final slot = slots[i];
      if (slot == null) {
        partial.add(backends[i].id);
      } else {
        updates.addAll(slot);
      }
    }
    return CheckUpdatesResult(updates: updates, partialBackendIds: partial);
  }

  /// Shared race skeleton behind [_checkOneWithTimeout] and
  /// [_installedOneWithTimeout]: `isAvailable()` (memoized per backend
  /// id — [_isAvailableCached], a cache read is instant and a cache
  /// miss re-probes under this same budget) + [fetch] raced against
  /// a single-shot timer from the host's injectable [TimerFactory]
  /// (never `Future.timeout` — zone timers aren't testable; the
  /// fake-factory pattern is the same as the stall watchdog).
  ///
  /// Returns the backend's items, or `null` when it is excluded:
  /// budget exceeded (timeout), a typed [StoreException], or a raw
  /// throw. The three classes are excluded identically — the taxonomy
  /// differs only in logs/telemetry (parallel-check-updates.md §4),
  /// and store_host owns no log sink, so no log lines here.
  ///
  /// The timeout aborts the *wait*, not the work: a backend that
  /// finishes late has its result dropped, and the orphan's async
  /// errors are absorbed so they can never surface as unhandled
  /// (same detach semantics as the watchdog).
  Future<List<T>?> _raceOne<T>(
    StoreBackend backend,
    Duration timeout,
    Future<List<T>> Function(StoreBackend) fetch,
  ) {
    final done = Completer<List<T>?>();
    Timer? timer;
    unawaited(() async {
      try {
        final available = await _isAvailableCached(backend);
        final items = available ? await fetch(backend) : <T>[];
        if (!done.isCompleted) {
          timer?.cancel();
          done.complete(items);
        }
      } catch (_) {
        // Timeout, typed StoreException, or raw throw — classification
        // in logs/telemetry only (parallel-check-updates.md §4);
        // handling is identical: exclude the backend, keep going.
        if (!done.isCompleted) {
          timer?.cancel();
          done.complete(null);
        }
      }
    }());
    timer = _timerFactory(timeout, () {
      // Budget exceeded: stop waiting. The orphan above keeps running
      // underneath; its late result is dropped and its errors absorbed.
      if (!done.isCompleted) done.complete(null);
    });
    return done.future;
  }

  /// One backend's share of the checkUpdates fan-out: `isAvailable()` +
  /// `checkUpdates()` raced against a single-shot timer
  /// (docs/architecture/parallel-check-updates.md §1) — implemented on
  /// the shared [_raceOne] skeleton.
  ///
  /// Returns the backend's updates, or `null` when it is excluded:
  /// budget exceeded (timeout), a typed [StoreException], or a raw
  /// throw.
  Future<List<UpdateInfo>?> _checkOneWithTimeout(
    StoreBackend backend,
    Duration timeout,
  ) => _raceOne(backend, timeout, (b) => b.checkUpdates());

  /// One backend's share of the installed fan-out: `isAvailable()` +
  /// `listInstalled()` raced against a single-shot timer
  /// (docs/architecture/parallel-installed.md §1) — implemented on
  /// the shared [_raceOne] skeleton.
  ///
  /// Returns the backend's installed apps, or `null` when it is
  /// excluded: budget exceeded (timeout), a typed [StoreException],
  /// or a raw throw.
  Future<List<AppInfo>?> _installedOneWithTimeout(
    StoreBackend backend,
    Duration timeout,
  ) => _raceOne(backend, timeout, (b) => b.listInstalled());

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    // Silent partial degradation: partiality details are available
    // via checkUpdatesDetailed(); this UnifiedCatalog override keeps
    // its signature and never-throws contract.
    return (await checkUpdatesDetailed()).updates;
  }

  /// Phase 3 cross-format identity resolution
  /// (docs/architecture/phase3-identity-hld.md).
  ///
  /// Returns null unless `phase3.identity.enabled` AND the local
  /// identity index resolves the identity. Null = unresolved = today's
  /// per-backend behavior (no behavior change when the flag is off:
  /// the index is never even loaded).
  ///
  /// The index loads lazily on first call and is cached for the host's
  /// lifetime (slice 1: no reload API): the bundled seed layer plus the
  /// local overlay at
  /// `~/.local/share/libreapp-center/identity-overlay.json` when
  /// `HOME` is set (no overlay when it is absent).
  Future<CanonicalAppId?> resolveIdentity(
    AppIdentity id, [
    IdentitySignal? signals,
  ]) async {
    if (!_flags.isEnabled('phase3.identity.enabled')) return null;
    var resolver = _identityResolver;
    if (resolver == null) {
      _identityIndex = await FileIdentityIndexStore().load(
        seedJson: kIdentitySeedJson,
        overlayPaths: _identityOverlayPaths(),
      );
      resolver = IdentityResolver(
        index: _identityIndex!,
        backends: {for (final b in _backends) b.id: b},
      );
      _identityResolver = resolver;
    }
    return resolver.resolve(id, signals);
  }

  /// Overlay paths for the lazy identity index (LLD §5.4): the local
  /// overlay only, resolved from `HOME`. Empty (no overlay) when `HOME`
  /// is absent — resolution falls back to the bundled seed.
  static List<String> _identityOverlayPaths() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return const [];
    return ['$home/.local/share/libreapp-center/identity-overlay.json'];
  }

  /// Backend-agnostic details lookup (host convenience, not in the
  /// [UnifiedCatalog] contract).
  Future<AppDetails> getDetails(AppIdentity app) async {
    final backend = _findBackend(app.backendId);
    if (backend == null) {
      throw BackendUnavailableException(
        debugDetail: 'backend ${app.backendId} not registered',
        backendId: app.backendId,
      );
    }
    return backend.getDetails(app);
  }

  @override
  Future<OperationHandle> enqueue(OperationKind kind, AppIdentity app) async {
    final key = _key(app);
    final existing = _inflight[key];
    // One active operation per AppIdentity: a second enqueue returns
    // the EXISTING handle — no duplicate downloads, no double
    // privilege prompts.
    if (existing != null && !existing.current.isTerminal) return existing;

    final backend = _findBackend(app.backendId);
    if (backend == null) {
      throw BackendUnavailableException(
        debugDetail: 'backend ${app.backendId} not registered',
        backendId: app.backendId,
      );
    }
    if (!_flags.isEnabled('backend.${backend.id}.enabled')) {
      throw BackendUnavailableException(
        debugDetail: 'backend ${backend.id} disabled by flag',
        backendId: backend.id,
      );
    }

    late final OperationHandle handle;
    switch (kind) {
      case OperationKind.install:
        handle = await backend.install(app);
      case OperationKind.remove:
        handle = await backend.remove(app);
      case OperationKind.update:
        handle = await backend.update(app);
    }
    // The engine watches every operation for stalls
    // (docs/architecture/stall-watchdog.md §2). The wrapper is the
    // handle the UI binds to; _watchTerminal/activeOperations see the
    // same object, so they need no changes.
    final timeoutMs = _flags.getInt('engine.stall_timeout_ms');
    final watched = _StallWatchedHandle(
      handle,
      stallTimeout: Duration(milliseconds: timeoutMs > 0 ? timeoutMs : 600000),
      timers: _timerFactory,
    );
    _inflight[key] = watched;
    _emitActive();
    unawaited(_watchTerminal(key, watched));
    return watched;
  }

  Future<void> _watchTerminal(String key, OperationHandle handle) async {
    try {
      await handle.state.where((s) => s.isTerminal).first;
    } catch (_) {
      // Stream errors/early close still release the slot.
    }
    if (identical(_inflight[key], handle)) {
      _inflight.remove(key);
      _emitActive();
    }
  }

  void _emitActive() {
    if (!_activeChanges.isClosed) {
      _activeChanges.add(_inflight.values.toList());
    }
  }

  @override
  Stream<List<OperationHandle>> activeOperations() {
    // Subscribe to changes BEFORE emitting the snapshot: broadcast
    // streams drop events with no listener, so the reverse order
    // could lose an update in between.
    final controller = StreamController<List<OperationHandle>>();
    final sub = _activeChanges.stream.listen(controller.add);
    controller.onCancel = () => sub.cancel();
    controller.add(_inflight.values.toList());
    return controller.stream;
  }

  @override
  Future<void> authenticateBatch(List<OperationHandle> ops) async {
    // v1: no-op. The CLI backends (flatpak) handle privilege
    // escalation per command; cross-command auth coalescing is a
    // vehicle-specific optimization for later.
  }
}

/// Engine-side stall watchdog
/// (docs/architecture/stall-watchdog.md §2, §9).
///
/// Wraps a backend's [OperationHandle]: forwards every inner state event
/// and re-arms a single-shot stall timer on each event in a watched
/// phase. Firing means the backend went silent for [stallTimeout]
/// mid-phase: the wrapper flags [isStalled] (advisory — the UI shows
/// "Stalled"), cancels the backend, and — if no terminal state arrives
/// within a 30s grace — synthesizes a terminal
/// `Failed(TimeoutException)` on its own stream and detaches. Later
/// inner events are ignored: a terminal state ends the wrapper's
/// stream for good.
class _StallWatchedHandle implements OperationHandle, StallAware {
  _StallWatchedHandle(
    OperationHandle inner, {
    required Duration stallTimeout,
    required TimerFactory timers,
  }) : _inner = inner,
       _stallTimeout = stallTimeout,
       _timers = timers {
    _sub = _inner.state.listen(_onInnerEvent);
    // The inner stream may never re-emit the phase it is already in —
    // arm off the current state as well, or a handle enqueued
    // mid-phase would never be watched.
    if (_isWatched(_inner.current)) {
      _stalledPhase = _inner.current;
      _armStallTimer();
    }
  }

  /// Grace after the watchdog cancels: the backend gets this long to
  /// reach a terminal state before the engine synthesizes one.
  static const _gracePeriod = Duration(seconds: 30);

  final OperationHandle _inner;
  final Duration _stallTimeout;
  final TimerFactory _timers;

  late final StreamSubscription<OperationState> _sub;
  final _states = StreamController<OperationState>.broadcast();
  final _stalledChanges = StreamController<bool>.broadcast();

  Timer? _stallTimer;
  Timer? _graceTimer;
  bool _stalled = false;
  bool _graceActive = false;
  bool _terminal = false;
  OperationState? _stalledPhase;

  @override
  String get id => _inner.id;

  @override
  AppIdentity get app => _inner.app;

  @override
  OperationKind get kind => _inner.kind;

  @override
  Stream<OperationState> get state => _states.stream;

  @override
  OperationState get current => _inner.current;

  @override
  bool get isStalled => _stalled;

  @override
  Stream<bool> get stalledChanges => _stalledChanges.stream;

  /// Delegates to the backend. Watchdog timers keep running: a user
  /// cancel races the watchdog honestly — whichever terminal wins.
  @override
  Future<void> cancel() => _inner.cancel();

  /// Phases where silence means the backend is working: no event for
  /// [stallTimeout] is a stall. `queued` is engine-owned waiting,
  /// `authenticating` is user-attended (a polkit prompt may legitimately
  /// sit for minutes), `cancelling` is governed by the cancel contract
  /// (operation-state-machine.md §3), not by this timer.
  static bool _isWatched(OperationState state) =>
      state is Restoring ||
      state is Preparing ||
      state is Downloading ||
      state is Verifying ||
      state is Applying;

  static String _phaseName(OperationState state) => switch (state) {
    Restoring() => 'Restoring',
    Preparing() => 'Preparing',
    Downloading() => 'Downloading',
    Verifying() => 'Verifying',
    Applying() => 'Applying',
    _ => state.runtimeType.toString(),
  };

  void _onInnerEvent(OperationState state) {
    // Detached (synthetic terminal already emitted): ignore everything
    // late. "Terminal states emit no further events. Ever."
    if (_terminal) return;
    if (!_states.isClosed) _states.add(state);
    if (state.isTerminal) {
      _onTerminal();
      return;
    }
    // Grace is running: the backend is winding down after the
    // watchdog's cancel; the grace timer owns the outcome now.
    if (_graceActive) return;
    if (_isWatched(state)) {
      _stalledPhase = state;
      _armStallTimer();
    } else {
      _disarmStallTimer();
    }
  }

  void _onTerminal() {
    _terminal = true;
    _disarmAll();
    unawaited(_sub.cancel());
  }

  /// The backend went silent for [stallTimeout] in a watched phase.
  void _onStall() {
    _stallTimer = null;
    if (_terminal) return;
    _stalled = true;
    if (!_stalledChanges.isClosed) _stalledChanges.add(true);
    // Cancel the backend; it gets a 30s grace to reach a terminal
    // state before the engine synthesizes one.
    unawaited(_inner.cancel());
    _graceActive = true;
    _graceTimer = _timers(_gracePeriod, _onGraceExpired);
  }

  /// Grace expired with no terminal: the backend is hung. Synthesize
  /// the terminal failure and detach; the backend may still be running
  /// underneath, but the engine no longer reports it.
  void _onGraceExpired() {
    _graceTimer = null;
    if (_terminal) return;
    _terminal = true;
    _graceActive = false;
    _disarmStallTimer();
    unawaited(_sub.cancel());
    final phase = _stalledPhase;
    final phaseName = phase == null ? 'unknown' : _phaseName(phase);
    if (!_states.isClosed) {
      _states.add(
        Failed(
          error: TimeoutException(
            debugDetail:
                'operation stalled in $phaseName; watchdog cancelled and '
                'the backend did not terminate within 30s',
            stalledPhase: phaseName,
          ),
        ),
      );
    }
  }

  void _armStallTimer() {
    _disarmStallTimer();
    _stallTimer = _timers(_stallTimeout, _onStall);
  }

  void _disarmStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _disarmAll() {
    _disarmStallTimer();
    _graceTimer?.cancel();
    _graceTimer = null;
    _graceActive = false;
  }
}
