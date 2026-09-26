/// Host-side contracts: catalog, engine, flags. The host implements
/// these; the UI consumes them. Backends never see these interfaces.
library;

import 'backend.dart';
import 'identity.dart';

/// One app across formats (ADR-007): the merged view the UI renders
/// as a single card with a format picker.
class UnifiedApp {
  const UnifiedApp({required this.groupId, required this.variants});

  /// Stable merge key for this app group.
  final String groupId;

  /// Per-format variants, ordered by host preference
  /// (installed first → exact name → rating → `catalog.backend_order`).
  final List<AppInfo> variants;

  /// The variant the Install button acts on by default.
  AppInfo get preferred => variants.first;
}

abstract class UnifiedCatalog {
  /// Fan-out search across all available+enabled backends in parallel.
  /// Streams [UnifiedApp] groups as backends respond.
  /// PRE: query 1..200 chars.
  /// A backend timing out degrades to a "partial results" badge —
  /// never fails the whole search.
  Stream<UnifiedApp> search(String query);

  /// Installed apps across all backends, merged.
  Future<List<UnifiedApp>> installed();

  /// Update check across backends — staggered, background, cached.
  /// MUST NOT run on the UI critical path at startup.
  Future<List<UpdateInfo>> checkUpdates();
}
