/// [StoreHost]: the composition point. Implements [UnifiedCatalog] and
/// [OperationEngine] over registered backends.
///
/// Grouping policy (v1): one [UnifiedApp] per [AppInfo] — no
/// cross-backend merging. The product thesis prefers duplicate cards
/// over unsafe merges; smart merging arrives with the community
/// metadata index, not with heuristics here.
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

class StoreHost implements UnifiedCatalog, OperationEngine {
  StoreHost({required FeatureFlags flags}) : _flags = flags;

  final FeatureFlags _flags;
  final List<StoreBackend> _backends = [];
  final Map<String, OperationHandle> _inflight = {};
  final StreamController<List<OperationHandle>> _activeChanges =
      StreamController<List<OperationHandle>>.broadcast();

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
      try {
        if (await b.isAvailable()) out.add(b);
      } catch (_) {
        // A throwing isAvailable() counts as unavailable.
      }
    }
    return out;
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

  @override
  Future<List<UnifiedApp>> installed() {
    // v1: not wired. Needs a `StoreBackend.listInstalled()` contract
    // addition (minor version bump + exam coverage) — tracked in
    // docs/architecture/host-wiring.md. Returns empty, never throws.
    return Future.value(const []);
  }

  @override
  Future<List<UpdateInfo>> checkUpdates() async {
    // Called off the UI critical path (staggered/background/cached is
    // the app's scheduling concern, not this method's).
    final out = <UpdateInfo>[];
    for (final b in await enabledBackends()) {
      try {
        out.addAll(await b.checkUpdates());
      } catch (_) {
        // Partial results, as with search.
      }
    }
    return out;
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
    _inflight[key] = handle;
    _emitActive();
    unawaited(_watchTerminal(key, handle));
    return handle;
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
