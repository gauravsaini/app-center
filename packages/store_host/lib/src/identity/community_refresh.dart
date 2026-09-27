/// [CommunityRefreshResult]: the outcome of
/// `StoreHost.refreshCommunityIndex`
/// (docs/architecture/phase3-slice3.md §5).
///
/// A result object, not a throw: refresh is an operator-initiated
/// maintenance action, and "all mirrors down" is an expected outcome,
/// not an exceptional one.
///
/// Exported for the Settings UI's community refresh controls
/// (docs/architecture/phase3-slice4.md §6).
library;

/// Outcome of a community index refresh. Exactly one of [isOk],
/// [isSkipped], [isFailed] is true.
class CommunityRefreshResult {
  /// A mirror's doc verified, was written to the community layer
  /// file, and the in-memory index reloaded.
  const CommunityRefreshResult.ok({
    required this.entryCount,
    required this.generatedAt,
    required this.mirror,
    required this.keyId,
  }) : _kind = _RefreshKind.ok,
       reason = null,
       errorsByMirror = const {};

  /// No fetch was attempted: a gate failed. Never an error.
  const CommunityRefreshResult.skipped(this.reason)
    : _kind = _RefreshKind.skipped,
      entryCount = 0,
      generatedAt = null,
      mirror = null,
      keyId = null,
      errorsByMirror = const {};

  /// Every mirror failed: the previous community file (if any) and
  /// the in-memory index are untouched.
  const CommunityRefreshResult.failed(this.errorsByMirror)
    : _kind = _RefreshKind.failed,
      entryCount = 0,
      generatedAt = null,
      mirror = null,
      keyId = null,
      reason = null;

  final _RefreshKind _kind;

  bool get isOk => _kind == _RefreshKind.ok;
  bool get isSkipped => _kind == _RefreshKind.skipped;
  bool get isFailed => _kind == _RefreshKind.failed;

  /// Entries in the verified doc. Set on [ok], 0 otherwise.
  final int entryCount;

  /// From the doc's `generatedAt` — informational only (staleness
  /// display), never a freshness gate. Set on [ok], null otherwise.
  final DateTime? generatedAt;

  /// The mirror URL whose doc won. Set on [ok], null otherwise.
  final String? mirror;

  /// The pinned curator keyId whose signature verified the winning
  /// doc. Set on [ok] (never null there), null otherwise. Displayed
  /// by the settings UI as "signature valid — key <keyId>".
  final String? keyId;

  /// Why no fetch was attempted. Set on [skipped], null otherwise.
  final String? reason;

  /// Per-mirror failure strings, in mirror order. Set on [failed],
  /// empty otherwise.
  final Map<String, String> errorsByMirror;

  @override
  String toString() => switch (_kind) {
    _RefreshKind.ok =>
      'CommunityRefreshResult.ok(entries: $entryCount, mirror: $mirror)',
    _RefreshKind.skipped => 'CommunityRefreshResult.skipped($reason)',
    _RefreshKind.failed =>
      'CommunityRefreshResult.failed(${errorsByMirror.length} mirrors)',
  };
}

enum _RefreshKind { ok, skipped, failed }
