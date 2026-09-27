/// [MapFeatureFlags]: in-memory [FeatureFlags] with documented defaults.
///
/// Key conventions (ADR-010):
/// - `backend.<id>.enabled` — backend kill switch.
/// - `catalog.backend_order` — preferred format order for dedup ranking.
/// - `catalog.search_timeout_ms`, `engine.stall_timeout_ms`,
///   `engine.max_concurrent_per_backend`, `engine.history_ttl_ms`.
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
    'engine.stall_timeout_ms': 30000,
    'engine.max_concurrent_per_backend': 1,
    'engine.history_ttl_ms': 3600000,
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
