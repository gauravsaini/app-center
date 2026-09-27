/// [FeatureFlags] — kill switches with owners (ADR-010).
///
/// Every flag records owner, default, and removal date in the registry
/// docs. A flag without a removal date is tech debt with a name.
///
/// Key conventions:
/// - `backend.<id>.enabled` — backend kill switch.
/// - `catalog.backend_order` — preferred format order for dedup ranking.
/// - `catalog.search_timeout_ms`, `engine.stall_timeout_ms`,
///   `engine.max_concurrent_per_backend`, `engine.history_ttl_ms`.
library;

abstract class FeatureFlags {
  /// Current value of a flag. Unknown keys return their documented
  /// default — never throw.
  bool isEnabled(String key);

  /// Typed accessors for well-known keys.
  int getInt(String key);
  String getString(String key);

  /// Stream of keys whose values changed.
  Stream<String> get changes;
}
