/// [StoreHost]: the composition point. Implements [UnifiedCatalog] and
/// [OperationEngine] over registered backends.
///
/// Grouping policy (v1): one [UnifiedApp] per [AppInfo] — no
/// cross-backend merging. The product thesis prefers duplicate cards
/// over unsafe merges; smart merging arrives with the community
/// metadata index, not with heuristics here.
///
/// When `phase3.identity.enabled` is true, [search] and
/// [installedDetailed] merge by canonical id instead
/// (docs/architecture/phase3-slice2.md §3); unresolved apps keep the v1
/// grouping bit for bit.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:store_contracts/store_contracts.dart';

import 'check_updates_result.dart';
import 'identity/community_crypto.dart';
import 'identity/community_refresh.dart';
import 'identity/community_transport.dart';
import 'identity/file_identity_index.dart';
import 'identity/identity_resolver.dart';
import 'identity/seed_index.dart';
import 'identity/source_preference_store.dart';
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

/// One canonical group under construction by [_mergeByIdentity]
/// (phase3-slice2.md §3): the merge key plus the resolved canonical id
/// (null when every member is unresolved) and the member variants in
/// input (registration) order.
class _MergeGroup {
  _MergeGroup(this.key, this.canonical);

  final String key;
  final CanonicalAppId? canonical;
  final List<AppInfo> variants = [];
}

class StoreHost implements UnifiedCatalog, OperationEngine {
  StoreHost({
    required FeatureFlags flags,
    TimerFactory? timerFactory,
    Clock? clock,
    String? sourcePreferencesPath,
    Map<String, String>? environment,
  }) : _flags = flags,
       _timerFactory = timerFactory ?? _realTimerFactory,
       _clock = clock ?? _realClock,
       _sourcePreferencesPath = sourcePreferencesPath,
       _environment = environment ?? Platform.environment;

  final FeatureFlags _flags;
  final TimerFactory _timerFactory;
  final Clock _clock;

  /// Process environment, injected for tests (default:
  /// [Platform.environment]). `HOME` locates the identity overlay and
  /// the community layer file.
  final Map<String, String> _environment;

  /// Overrides the source-preferences file location (tests). Null →
  /// the store resolves `~/.local/share/libreapp-center/
  /// source-preferences.json` from `HOME` (in-memory only when `HOME`
  /// is absent).
  final String? _sourcePreferencesPath;
  final List<StoreBackend> _backends = [];
  final Map<String, OperationHandle> _inflight = {};
  final StreamController<List<OperationHandle>> _activeChanges =
      StreamController<List<OperationHandle>>.broadcast();

  /// Memoized `isAvailable()` results per backend id
  /// (docs/architecture/platform-detection.md §4).
  final Map<String, _ProbeCacheEntry> _probeCache = {};

  /// Lazy Phase 3 identity plumbing (phase3-identity-hld.md). Built on
  /// the first [resolveIdentity] call and cached for the host's
  /// lifetime — [reloadIdentityIndex] drops the cache so the next
  /// call rebuilds from disk (phase3-slice3.md §6). Never built when
  /// `phase3.identity.enabled` is false.
  IdentityIndex? _identityIndex;
  IdentityResolver? _identityResolver;

  /// Lazy Phase 3 source-preference store (phase3-slice2.md §4): the
  /// user's per-app remembered source choice (HLD §6 rule 2). Built on
  /// first use and cached for the host's lifetime — slice 2 has no
  /// reload API.
  SourcePreferenceStore? _preferenceStore;

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
        // Phase 3 (phase3-slice2.md §3): when identity merging is on,
        // AppInfos buffer until every backend has responded, then
        // merge by canonical id. Flag off → per-app emission, exactly
        // today's behavior.
        final identityMerge = _flags.isEnabled('phase3.identity.enabled');
        final buffered = <AppInfo>[];
        void finishOne() {
          if (--pending == 0) {
            unawaited(_finishSearch(controller, identityMerge, buffered));
          }
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
                      if (identityMerge) {
                        buffered.add(app);
                      } else {
                        controller.add(
                          UnifiedApp(
                            groupId: '${b.id}:${app.identity.nativeId}',
                            variants: [app],
                          ),
                        );
                      }
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

  /// Closes out a search fan-out. With identity merging on, the
  /// buffered [AppInfo]s are resolved, grouped, and ordered
  /// (phase3-slice2.md §3) before emission; otherwise the per-app
  /// stream already carried everything and the controller just closes.
  Future<void> _finishSearch(
    StreamController<UnifiedApp> controller,
    bool identityMerge,
    List<AppInfo> buffered,
  ) async {
    try {
      if (identityMerge && !controller.isClosed) {
        for (final app in await _mergeByIdentity(buffered)) {
          if (controller.isClosed) break;
          controller.add(app);
        }
      }
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  /// Groups [apps] into [UnifiedApp]s by canonical id
  /// (phase3-slice2.md §3). Each app is resolved via [resolveIdentity];
  /// resolved apps merge on the canonical id string, unresolved apps
  /// keep today's `${backendId}:${nativeId}` key — bit for bit the v1
  /// grouping for the unresolved case. Group emission order is
  /// first-seen (registration order of the input); variants inside a
  /// group follow the HLD §6 merge policy — installed wins → user
  /// preference → `catalog.backend_order` → registration order.
  /// `preferred` is `variants.first` — no special-casing.
  Future<List<UnifiedApp>> _mergeByIdentity(List<AppInfo> apps) async {
    final groups = <String, _MergeGroup>{};
    for (final app in apps) {
      final canonical = await resolveIdentity(app.identity, app.identitySignal);
      final key =
          canonical?.toString() ??
          '${app.identity.backendId}:${app.identity.nativeId}';
      (groups[key] ??= _MergeGroup(key, canonical)).variants.add(app);
    }
    final prefs = await _preferences();
    final backendOrder = _flags
        .getString('catalog.backend_order')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return [
      for (final group in groups.values)
        UnifiedApp(
          groupId: group.key,
          canonicalId: group.canonical,
          variants: _orderVariants(
            group.variants,
            group.canonical,
            prefs,
            backendOrder,
          ),
        ),
    ];
  }

  /// HLD §6 variant ordering, verbatim:
  /// 1. installed source wins (`installedVersion != null` first),
  /// 2. user preference ([SourcePreferenceStore], keyed by canonical
  ///    id string; an id no variant recognizes is ignored),
  /// 3. `catalog.backend_order` flag index (unlisted backends rank
  ///    after all listed ones),
  /// 4. registration order (explicit input index — never sort
  ///    stability).
  List<AppInfo> _orderVariants(
    List<AppInfo> variants,
    CanonicalAppId? canonical,
    SourcePreferenceStore prefs,
    List<String> backendOrder,
  ) {
    final preferredBackend = canonical == null
        ? null
        : prefs.preferenceFor(canonical.toString());
    int rank(String backendId) {
      final idx = backendOrder.indexOf(backendId);
      return idx < 0 ? backendOrder.length : idx;
    }

    final indexed = [
      for (var i = 0; i < variants.length; i++) (i, variants[i]),
    ];
    indexed.sort((x, y) {
      // 1. Installed source wins.
      final xi = x.$2.installedVersion != null ? 0 : 1;
      final yi = y.$2.installedVersion != null ? 0 : 1;
      if (xi != yi) return xi.compareTo(yi);
      // 2. User preference.
      if (preferredBackend != null) {
        final xp = x.$2.identity.backendId == preferredBackend ? 0 : 1;
        final yp = y.$2.identity.backendId == preferredBackend ? 0 : 1;
        if (xp != yp) return xp.compareTo(yp);
      }
      // 3. Flag order.
      final xo = rank(x.$2.identity.backendId);
      final yo = rank(y.$2.identity.backendId);
      if (xo != yo) return xo.compareTo(yo);
      // 4. Registration order.
      return x.$1.compareTo(y.$1);
    });
    return [for (final (_, v) in indexed) v];
  }

  /// Remembers the user's source choice for one canonical app
  /// (phase3-slice2.md §4, HLD §6 rule 2). The [backendId] is stored
  /// verbatim — an id no backend recognizes is kept and ignored at
  /// ordering time. Survives restarts via
  /// `~/.local/share/libreapp-center/source-preferences.json`.
  Future<void> setPreferredSource(CanonicalAppId id, String backendId) async {
    final store = await _preferences();
    await store.setPreferred(id.toString(), backendId);
  }

  /// Lazy source-preference store, built on first use and cached for
  /// the host's lifetime (slice 2: no reload API). The load never
  /// throws (corrupt/missing file → empty preferences).
  Future<SourcePreferenceStore> _preferences() async {
    var store = _preferenceStore;
    if (store == null) {
      store = SourcePreferenceStore(filePath: _sourcePreferencesPath);
      await store.load();
      _preferenceStore = store;
    }
    return store;
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
  ///
  /// When `phase3.identity.enabled` is true, apps merge by canonical id
  /// instead (docs/architecture/phase3-slice2.md §3); unresolved apps
  /// keep the v1 per-backend grouping bit for bit.
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
    final identityMerge = _flags.isEnabled('phase3.identity.enabled');
    final toMerge = <AppInfo>[];
    for (var i = 0; i < backends.length; i++) {
      final slot = slots[i];
      if (slot == null) {
        partial.add(backends[i].id);
        continue;
      }
      if (identityMerge) {
        toMerge.addAll(slot);
      } else {
        for (final app in slot) {
          apps.add(
            UnifiedApp(
              groupId: '${backends[i].id}:${app.identity.nativeId}',
              variants: [app],
            ),
          );
        }
      }
    }
    return InstalledResult(
      apps: identityMerge ? await _mergeByIdentity(toMerge) : apps,
      partialBackendIds: partial,
    );
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
  /// lifetime, reloadable via [reloadIdentityIndex]: the bundled seed
  /// layer, then the community layer at
  /// `~/.local/share/libreapp-center/identity-community.json`, then
  /// the local overlay at
  /// `~/.local/share/libreapp-center/identity-overlay.json` — both
  /// `HOME`-relative, both absent when `HOME` is unset.
  Future<CanonicalAppId?> resolveIdentity(
    AppIdentity id, [
    IdentitySignal? signals,
  ]) async {
    if (!_flags.isEnabled('phase3.identity.enabled')) return null;
    var resolver = _identityResolver;
    if (resolver == null) {
      _identityIndex = await FileIdentityIndexStore().load(
        seedJson: kIdentitySeedJson,
        communityPaths: _identityCommunityPaths(),
        overlayPaths: _identityOverlayPaths(environment: _environment),
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
  /// overlay only, resolved from the given environment. Empty (no
  /// overlay) when `HOME` is absent — resolution falls back to the
  /// bundled seed.
  static List<String> _identityOverlayPaths({
    required Map<String, String> environment,
  }) {
    final home = environment['HOME'];
    if (home == null || home.isEmpty) return const [];
    return ['$home/.local/share/libreapp-center/identity-overlay.json'];
  }

  /// Community layer file for the lazy identity index
  /// (phase3-slice3.md §5): the operator-fetched, signature-verified
  /// community doc lives here — written ONLY by
  /// [refreshCommunityIndex], after verification. Null when `HOME` is
  /// absent: refresh then reports `skipped`, and resolution falls
  /// back to seed + local overlay.
  static String? _communityLayerPath({
    required Map<String, String> environment,
  }) {
    final home = environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.local/share/libreapp-center/identity-community.json';
  }

  /// Community layer paths for the lazy identity index: the fetched
  /// file above, or empty when `HOME` is absent (no community file).
  List<String> _identityCommunityPaths() {
    final path = _communityLayerPath(environment: _environment);
    return path == null ? const [] : [path];
  }

  /// Drops the cached identity index and resolver
  /// (docs/architecture/phase3-slice3.md §6). The next
  /// [resolveIdentity] call reloads from disk — bundled seed, then
  /// the community layer, then the local overlay, in that priority
  /// order.
  ///
  /// Reload contract: the swap replaces the immutable
  /// [IdentityIndex]/[IdentityResolver] references, so in-flight
  /// resolutions finish on the old index (no tearing, no locks).
  /// Never throws: worst case the next load yields the seed-only
  /// index ([FileIdentityIndexStore.load] never throws).
  void reloadIdentityIndex() {
    _identityIndex = null;
    _identityResolver = null;
  }

  /// Fetches, verifies, and installs the community identity index
  /// layer (docs/architecture/phase3-slice3.md §5).
  ///
  /// The flow: gate (identity enabled + community enabled + mirrors
  /// non-empty + `HOME` present, else `skipped`) → per mirror
  /// (https-only): fetch → parse JSON object → verify the Ed25519
  /// signature envelope → atomic write (temp + rename) to the
  /// community layer file → [reloadIdentityIndex] → `ok`. All
  /// mirrors fail → `failed` with per-mirror error strings; the
  /// previous community file (if any) and the in-memory index are
  /// untouched.
  ///
  /// Explicit-only: nothing in the host ever calls this on a timer or
  /// at startup — there is no automatic download anywhere. Never
  /// throws: "all mirrors down" is an expected outcome, reported as
  /// `failed`, not an exception.
  Future<CommunityRefreshResult> refreshCommunityIndex({
    CommunityIndexTransport? transport,
    CommunityTrustStore trust = CommunityTrustStore.bootstrap,
  }) async {
    if (!_flags.isEnabled('phase3.identity.enabled')) {
      return const CommunityRefreshResult.skipped(
        'phase3.identity.enabled is false',
      );
    }
    if (!_flags.isEnabled('phase3.community.enabled')) {
      return const CommunityRefreshResult.skipped(
        'phase3.community.enabled is false',
      );
    }
    final mirrors = _flags
        .getString('phase3.community.mirrors')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (mirrors.isEmpty) {
      return const CommunityRefreshResult.skipped(
        'phase3.community.mirrors is empty — no fetch, ever',
      );
    }
    final communityPath = _communityLayerPath(environment: _environment);
    if (communityPath == null) {
      return const CommunityRefreshResult.skipped(
        'HOME is not set — no community layer file location',
      );
    }

    final fetcher = transport ?? HttpCommunityIndexTransport();
    final errors = <String, String>{};
    for (final mirror in mirrors) {
      final uri = Uri.tryParse(mirror);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        errors[mirror] = 'skipped: only https:// mirror URLs are accepted';
        continue;
      }
      final String body;
      try {
        body = await fetcher.fetch(uri);
      } on CommunityFetchException catch (e) {
        errors[mirror] = 'fetch failed: ${e.message}';
        continue;
      } catch (e) {
        // A transport that throws something else must not take the
        // refresh down with it either.
        errors[mirror] = 'fetch failed: $e';
        continue;
      }
      final Map<String, Object?> raw;
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, Object?>) {
          raw = decoded;
        } else if (decoded is Map) {
          raw = Map<String, Object?>.from(decoded);
        } else {
          errors[mirror] = 'parse failed: not a JSON object';
          continue;
        }
      } on FormatException catch (e) {
        errors[mirror] = 'parse failed: ${e.message}';
        continue;
      }
      final VerifiedCommunityDoc verified;
      try {
        verified = await verifyCommunityDoc(raw, trust);
      } on CommunitySignatureException catch (e) {
        errors[mirror] = 'signature rejected: ${e.message}';
        continue;
      } on Exception catch (e) {
        // verifyCommunityDoc only throws CommunitySignatureException
        // by contract, but a mirror's doc must never take the refresh
        // down with an unexpected exception either.
        errors[mirror] = 'signature rejected: $e';
        continue;
      }
      try {
        // Verify-before-write: the previous community file is only
        // replaced after a doc FULLY verifies.
        await _atomicWriteFile(communityPath, body);
      } on IOException catch (e) {
        errors[mirror] = 'write failed: $e';
        continue;
      }
      reloadIdentityIndex();
      final entries = verified.doc['entries'];
      return CommunityRefreshResult.ok(
        entryCount: entries is List ? entries.length : 0,
        generatedAt: verified.generatedAt,
        mirror: mirror,
      );
    }
    return CommunityRefreshResult.failed(errors);
  }

  /// Atomic file swap: write to `<path>.tmp` then rename. A crash
  /// mid-write never leaves a half-written layer file. Throws
  /// [IOException] on unrecoverable I/O — the refresh caller catches
  /// it per mirror and reports `failed`, leaving the previous layer
  /// and the in-memory index untouched.
  static Future<void> _atomicWriteFile(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(content);
    await tmp.rename(path);
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
