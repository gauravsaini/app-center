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
  MapFeatureFlags([Map<String, Object>? seed])
    : _values = {..._defaults, ...?seed};

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
    // Kill switch for the AppImage backend plugin (Phase 1): false →
    // backend never registered, host behaves as if AppImage support
    // does not exist. Default off: new backend, needs dogfooding.
    // Owner: libreapp-center. Removal date: 2027-06-30 (ADR-010).
    'backend.appimage.enabled': false,
  };

  final Map<String, Object> _values;
  final _changes = StreamController<String>.broadcast();

  /// Mutate a flag (settings UI, experiments, tests).
  void setFlag(String key, Object value) {
    _values[key] = value;
    if (!_changes.isClosed) _changes.add(key);
  }

  @override
  bool isEnabled(String key) {
    final v = _values[key] ?? _defaults[key];
    return v is bool ? v : false;
  }

  @override
  int getInt(String key) {
    final v = _values[key] ?? _defaults[key];
    return v is int ? v : 0;
  }

  @override
  String getString(String key) {
    final v = _values[key] ?? _defaults[key];
    return v is String ? v : '';
  }

  @override
  Stream<String> get changes => _changes.stream;
}
