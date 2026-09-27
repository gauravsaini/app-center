/// [MapFeatureFlags]: in-memory [FeatureFlags] with documented defaults.
///
/// Key conventions (ADR-010):
/// - `backend.<id>.enabled` — backend kill switch.
/// - `catalog.backend_order` — preferred format order for dedup ranking.
/// - `catalog.search_timeout_ms`, `engine.stall_timeout_ms`,
///   `engine.max_concurrent_per_backend`, `engine.history_ttl_ms`.
/// - `pages.<page>.unified` — per-page strangler switch: `true` means the
///   page reads from [StoreHost], `false` keeps the legacy path.
///   Owner: `libreapp-center`; removal date: `2027-06-30` — every flag
///   needs an owner and a removal date before it ships to users (ADR-010).
library;

import 'dart:async';

import 'package:store_contracts/store_contracts.dart';

class MapFeatureFlags implements FeatureFlags {
  /// [seed] holds explicit overrides (tests, composition root) — user
  /// mutations, not defaults: they live in [_values] and always win
  /// over the [_seeded] detected-defaults layer below.
  ///
  /// [_values] intentionally does NOT copy [_defaults]: the lookup
  /// chain is `_values[key] ?? _seeded[key] ?? _defaults[key]`, so a
  /// pre-populated `_values` would shadow the seeded layer and make
  /// platform seeding a no-op (platform-detection.md §3).
  MapFeatureFlags([Map<String, Object>? seed]) : _values = {...?seed};

  /// Documented defaults. Unknown keys fall back here; keys unknown
  /// everywhere read as `false`/`0`/`''` — never throw.
  static const _defaults = <String, Object>{
    'backend.flatpak.enabled': true,
    'backend.snap.enabled': true,
    'backend.deb.enabled': true,
    'catalog.backend_order': 'flatpak,snap,deb',
    'catalog.search_timeout_ms': 5000,
    // Stall watchdog default (docs/architecture/stall-watchdog.md §5):
    // 10 min. A 30s watchdog would false-positive against the 60s
    // backend heartbeat — a healthy backend may legitimately go 60s
    // silent in a long phase. Previously 30000 and never consumed,
    // so the change is safe.
    'engine.stall_timeout_ms': 600000,
    'engine.max_concurrent_per_backend': 1,
    'engine.history_ttl_ms': 3600000,
    // Strangler switch for the Manage page (installed apps):
    // true → page reads StoreHost.installed(), false → legacy path.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'pages.manage.unified': false,
    // Strangler switch for the updates surface (Manage page updates
    // section, nav badge, update-all): true → reads
    // unifiedUpdatesProvider (StoreHost.checkUpdates()), false →
    // legacy update models (snapUpdatesModelProvider,
    // localDebUpdatesModelProvider).
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'pages.updates.unified': false,
    // Poll interval for the background update check
    // (docs/architecture/update-polling.md §7): 6h. <= 0 disables
    // polling. Only consumed when `pages.updates.unified` is true.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'updates.poll_interval_ms': 21600000,
    // Per-backend budget for an update check
    // (docs/architecture/parallel-check-updates.md §2): 30s. Covers
    // isAvailable() + checkUpdates() per backend in the
    // checkUpdatesDetailed() fan-out. <= 0 falls back to this default,
    // never disables: a timeout is a safety bound, not a feature —
    // disabling it reintroduces the hang this budget kills. Read at
    // call time, never cached.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'updates.backend_timeout_ms': 30000,
    'installed.backend_timeout_ms': 30000, // Per-backend budget for the
    // installed listing (docs/architecture/parallel-installed.md §2).
    // Covers isAvailable() + listInstalled() per backend in the
    // installedDetailed() fan-out. <= 0 falls back to this default,
    // never disables. Read at call time, never cached.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    // Kill switch for the AppImage backend plugin (Phase 1): false →
    // backend excluded from fan-outs and enqueue throws
    // BackendUnavailableException; the backend is still registered
    // (registration is unconditional — the flag is the filter).
    // Default off: new backend, needs dogfooding.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'backend.appimage.enabled': false,
    // Kill switch for the RPM backend plugin: false → backend excluded
    // from fan-outs and enqueue throws BackendUnavailableException; the
    // backend is still registered (registration is unconditional — the
    // flag is the filter).
    // Default off: new backend, needs dogfooding. Platform seeding that
    // enables this on fedora-like systems is a separate, deferred
    // decision (docs/architecture/rpm-backend-hld.md §5).
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'backend.rpm.enabled': false,
    // isAvailable() memoization TTL
    // (docs/architecture/platform-detection.md §4): 30s. <= 0 disables
    // caching entirely — a cache you can disable is a debugging tool,
    // not a feature. Read at call time, never cached.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'host.probe_cache_ttl_ms': 30000,
  };

  final Map<String, Object> _values;

  /// Seeded defaults (docs/architecture/platform-detection.md §3):
  /// values detected at startup (platform family), consulted after
  /// user mutations ([_values]) and before compiled [_defaults]:
  ///
  /// ```dart
  /// _values[key] ?? _seeded[key] ?? _defaults[key]
  /// ```
  ///
  /// Startup-only: emits no [changes] event. Later [setFlag] always
  /// wins — seeding is the detected default, the user has the final
  /// word.
  final Map<String, Object> _seeded = {};
  final _changes = StreamController<String>.broadcast();

  /// Seed a *detected* default (platform-detection.md §3).
  void seedDefault(String key, Object value) {
    _seeded[key] = value;
  }

  /// Mutate a flag (settings UI, experiments, tests).
  void setFlag(String key, Object value) {
    _values[key] = value;
    if (!_changes.isClosed) _changes.add(key);
  }

  @override
  bool isEnabled(String key) {
    final v = _values[key] ?? _seeded[key] ?? _defaults[key];
    return v is bool ? v : false;
  }

  @override
  int getInt(String key) {
    final v = _values[key] ?? _seeded[key] ?? _defaults[key];
    return v is int ? v : 0;
  }

  @override
  String getString(String key) {
    final v = _values[key] ?? _seeded[key] ?? _defaults[key];
    return v is String ? v : '';
  }

  @override
  Stream<String> get changes => _changes.stream;
}
