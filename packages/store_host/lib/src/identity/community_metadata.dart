/// Community app metadata: descriptions, screenshots, permissions,
/// ratings (Phase 3 identity, slice 5).
///
/// Implements `docs/architecture/phase3-slice5.md` §1–§2, §8. The
/// metadata doc is a second signed document distributed over the slice-3
/// channel (`community_crypto.dart`, `community_transport.dart`) and
/// written — only after full verification — to
/// `~/.local/share/libreapp-center/identity-metadata.json`.
///
/// Strictness lives at the parse layer (`fromJson` throws
/// [FormatException] on bad shape); forgiveness lives at the load
/// layer ([CommunityMetadataStore] skips malformed records and counts
/// them; malformed sub-blocks — a bad screenshot, an invalid
/// permissions block, a rating without a count — drop the block, never
/// the record). Same split as slices 1–3.
///
/// Empty string = absent (never emit empty signals): empty
/// summary/description/caption parse to null.
///
/// Host-internal plumbing except [CommunityAppMetadata] and
/// [CommunityMetadataRefreshResult], which are exported from
/// `store_host.dart` for the details UI (same pattern as slice 4 §6).
library;

import 'dart:convert';
import 'dart:io';

import 'package:store_contracts/store_contracts.dart';

/// Sandboxing level for a community permissions block (§1.1).
///
/// Host-internal: the UI reads it through [CommunityAppMetadata]
/// without naming this type.
enum CommunitySandboxing {
  /// Unsandboxed formats (deb/rpm/pacman/appimage): the only honest
  /// statement is the atomic `full-system-trust`, alone.
  unsandboxed,

  /// Sandboxed formats (snap strict, flatpak): finer capabilities may
  /// be claimed, but never `full-system-trust`.
  sandboxed,

  /// Curators have not reviewed this app: with an empty capability
  /// list this renders as the absent block, not as a claim (§1.1
  /// rule 4).
  unknown,
}

/// One community-curated screenshot (§1).
///
/// Host-internal: [fromJson] throws [FormatException] when the URL is
/// missing, empty, or not https — the caller drops the screenshot and
/// keeps the record. NEVER embedded binaries: a mirror serving a 2 GB
/// doc is a DoS vector (the 10 MiB body cap lives in the refresh
/// path, §2).
class CommunityScreenshot {
  const CommunityScreenshot({required this.url, this.caption});

  /// The https URL. Parse-validated — non-https never reaches the UI.
  final String url;

  /// Optional caption. Empty string parses to null (absent).
  final String? caption;

  /// Parses [json] as a screenshot. Throws [FormatException] when
  /// `url` is missing/empty/not-https. A non-string `caption` parses
  /// to null (forgiving — the URL is the payload).
  factory CommunityScreenshot.fromJson(Map<String, Object?> json) {
    final url = json['url'];
    if (url is! String || url.isEmpty) {
      throw const FormatException(
        'community screenshot has missing or empty url',
      );
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw FormatException('community screenshot url is not https: $url');
    }
    final caption = json['caption'];
    return CommunityScreenshot(
      url: url,
      caption: caption is String && caption.isNotEmpty ? caption : null,
    );
  }
}

/// Community-curated permission claims for one app (§1.1).
///
/// Format-agnostic CURATED claims — what the upstream project
/// legitimately needs, reviewed by curators — marked with [source].
/// The sandboxing TRUTH stays backend-reported at details time (snap
/// confinement from the store, flatpak's live `--show-permissions`,
/// deb/rpm/pacman/appimage honestly reporting `full-system-trust`);
/// this block never enters the ADR-009 pre-install position.
///
/// Host-internal: [fromJson] enforces the §1.1 parser invariants and
/// throws [FormatException] when any is violated — the caller drops
/// the block and keeps the record.
class CommunityPermissions {
  const CommunityPermissions({
    required this.sandboxing,
    this.capabilities = const [],
    this.source,
  });

  /// Closed capability vocabulary v1 (§1.1). Unknown ids → the block
  /// is dropped (forward compatibility at the load layer, strictness
  /// at parse).
  static const Set<String> vocabulary = {
    // Atomic: unsandboxed formats ONLY, alone. Enumerating finer
    // permissions for a package that can do everything would be
    // fabrication — the parser rejects any pairing.
    'full-system-trust',
    'network',
    'home.read',
    'home.write',
    'system.read',
    'system.write',
    'audio.playback',
    'audio.record',
    'camera',
    'location',
    'usb.devices',
    'notifications',
    'background',
  };

  final CommunitySandboxing sandboxing;

  /// Curated capability claims from [vocabulary].
  final List<String> capabilities;

  /// `'upstream-manifest'` | `'curated-review'`. The curated-review
  /// mark makes staleness attributable (snap strict interfaces are
  /// per-revision; the doc may describe an older one).
  final String? source;

  /// Parses [json], enforcing the §1.1 invariants. Throws
  /// [FormatException] when violated:
  /// 1. `sandboxing: unsandboxed` requires `capabilities ==
  ///    ['full-system-trust']` exactly.
  /// 2. `full-system-trust` alongside any other capability is
  ///    rejected (it is atomic).
  /// 3. `sandboxing: sandboxed` forbids `full-system-trust`.
  /// 4. (Handled by the caller: `unknown` + empty capabilities =
  ///    unreviewed → absent block.)
  /// Unknown capability ids and unknown `sandboxing`/`source` values
  /// also throw.
  factory CommunityPermissions.fromJson(Map<String, Object?> json) {
    final sandboxing = switch (json['sandboxing']) {
      'unsandboxed' => CommunitySandboxing.unsandboxed,
      'sandboxed' => CommunitySandboxing.sandboxed,
      'unknown' => CommunitySandboxing.unknown,
      final other => throw FormatException(
        'community permissions has unknown sandboxing: $other',
      ),
    };
    final capabilities = <String>[];
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities != null) {
      if (rawCapabilities is! List) {
        throw const FormatException(
          'community permissions capabilities is not a list',
        );
      }
      for (final c in rawCapabilities) {
        if (c is! String || !vocabulary.contains(c)) {
          throw FormatException(
            'community permissions has unknown capability: $c',
          );
        }
        capabilities.add(c);
      }
    }
    final hasFullTrust = capabilities.contains('full-system-trust');
    if (hasFullTrust && capabilities.length > 1) {
      throw const FormatException(
        'community permissions: full-system-trust is atomic — cannot '
        'pair it with other capabilities',
      );
    }
    if (sandboxing == CommunitySandboxing.unsandboxed &&
        !(hasFullTrust && capabilities.length == 1)) {
      throw const FormatException(
        'community permissions: sandboxing unsandboxed requires '
        "capabilities == ['full-system-trust'] exactly",
      );
    }
    if (sandboxing == CommunitySandboxing.sandboxed && hasFullTrust) {
      throw const FormatException(
        'community permissions: sandboxing sandboxed forbids '
        'full-system-trust',
      );
    }
    final source = json['source'];
    if (source != null &&
        source != 'upstream-manifest' &&
        source != 'curated-review') {
      throw FormatException(
        'community permissions has unknown source: $source',
      );
    }
    return CommunityPermissions(
      sandboxing: sandboxing,
      capabilities: capabilities,
      source: source as String?,
    );
  }
}

/// Read-only community rating aggregate (§1.2).
///
/// Host-internal: [fromJson] throws [FormatException] when `mean` is
/// outside 0–5 or `count` < 1 — the caller drops the rating and keeps
/// the record. No mean without count, ever (ADR-005: a mean with no
/// count is exactly the fake score ADR-005 forbids). `null` = no data,
/// never `0.0`-as-unknown.
class CommunityRating {
  const CommunityRating({required this.mean, required this.count});

  /// 0–5 inclusive.
  final double mean;

  /// Positive int. Always shown alongside the mean ("4.3 · 128
  /// community ratings") so a 5.0 from 3 ratings reads as what it is.
  final int count;

  /// Parses [json] as a rating aggregate. Throws [FormatException]
  /// when `mean`/`count` are missing, mistyped, or out of range.
  factory CommunityRating.fromJson(Map<String, Object?> json) {
    final mean = json['mean'];
    final count = json['count'];
    if (mean is! num || count is! int) {
      throw const FormatException(
        'community rating needs a numeric mean and an int count — '
        'no mean without count, ever',
      );
    }
    if (mean < 0 || mean > 5) {
      throw FormatException('community rating mean $mean outside 0–5');
    }
    if (count < 1) {
      throw FormatException('community rating count $count < 1');
    }
    return CommunityRating(mean: mean.toDouble(), count: count);
  }
}

/// Community-curated metadata for one canonical app (§1).
///
/// Keyed by [canonicalId] — [CanonicalAppId.parse] strictness applies.
/// Metadata for an app with no canonical id does not exist in v1:
/// unresolved apps show backend data only. Unknown top-level and
/// per-record fields are ignored (forward compatibility).
///
/// Exported for the details UI (`store_host.dart`).
class CommunityAppMetadata {
  const CommunityAppMetadata({
    required this.canonicalId,
    this.summary,
    this.description,
    this.screenshots = const [],
    this.permissions,
    this.rating,
    this.provenance = const IdentityProvenance(source: 'community'),
  });

  /// Strict canonical id — the metadata key.
  final CanonicalAppId canonicalId;

  /// Editorial short text. Empty string parses to null (absent).
  final String? summary;

  /// Editorial long text. Wins over the backend's
  /// `AppDetails.description` when present (labeled). Empty string
  /// parses to null (absent).
  final String? description;

  /// https-only, parse-validated. Non-https entries are dropped at
  /// parse, never the record.
  final List<CommunityScreenshot> screenshots;

  /// Curated capability claims. Null = unreviewed (including the
  /// `unknown` + empty-capabilities "not reviewed" shape, §1.1
  /// rule 4). Never in the ADR-009 position.
  final CommunityPermissions? permissions;

  /// Read-only aggregate. Null = no data (ADR-005).
  final CommunityRating? rating;

  /// Where the record came from. Defaults to `community`.
  final IdentityProvenance provenance;

  /// Parses [json] as one metadata record. Throws [FormatException]
  /// on bad record shape (bad `canonicalId`, non-string editorial
  /// fields, non-list `screenshots`, non-object
  /// `permissions`/`rating`/`provenance`) — the load layer skips the
  /// record and counts it. Unknown fields are ignored. Malformed
  /// SUB-blocks (one bad screenshot, an invalid permissions block, a
  /// rating without a count) drop the block, never the record.
  factory CommunityAppMetadata.fromJson(Map<String, Object?> json) {
    final rawCanonicalId = json['canonicalId'];
    if (rawCanonicalId is! String) {
      throw const FormatException(
        'community metadata record has missing or non-string canonicalId',
      );
    }
    // Strict parse — a record keyed by a non-canonical id is a data
    // bug, not a record to keep.
    final canonicalId = CanonicalAppId.parse(rawCanonicalId);

    String? textField(String name) {
      final value = json[name];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException(
          'community metadata record field $name is not a string',
        );
      }
      // Empty string = absent (never emit empty signals).
      return value.isEmpty ? null : value;
    }

    final screenshots = <CommunityScreenshot>[];
    final rawScreenshots = json['screenshots'];
    if (rawScreenshots != null) {
      if (rawScreenshots is! List) {
        throw const FormatException(
          'community metadata record screenshots is not a list',
        );
      }
      for (final item in rawScreenshots) {
        // One bad screenshot drops the screenshot, never the record.
        if (item is! Map) continue;
        try {
          screenshots.add(
            CommunityScreenshot.fromJson(Map<String, Object?>.from(item)),
          );
        } on FormatException {
          continue;
        }
      }
    }

    CommunityPermissions? permissions;
    final rawPermissions = json['permissions'];
    if (rawPermissions != null) {
      if (rawPermissions is! Map) {
        throw const FormatException(
          'community metadata record permissions is not an object',
        );
      }
      try {
        final parsed = CommunityPermissions.fromJson(
          Map<String, Object?>.from(rawPermissions),
        );
        // §1.1 rule 4: unknown sandboxing + empty capabilities =
        // "curators haven't reviewed this app" → absent block.
        permissions =
            parsed.sandboxing == CommunitySandboxing.unknown &&
                parsed.capabilities.isEmpty
            ? null
            : parsed;
      } on FormatException {
        // Invalid block drops the block, never the record.
        permissions = null;
      }
    }

    CommunityRating? rating;
    final rawRating = json['rating'];
    if (rawRating != null) {
      // A rating without a count (or any other violation) drops the
      // rating, never the record (ADR-005: no mean without count).
      if (rawRating is Map) {
        try {
          rating = CommunityRating.fromJson(
            Map<String, Object?>.from(rawRating),
          );
        } on FormatException {
          rating = null;
        }
      } else {
        rating = null;
      }
    }

    IdentityProvenance provenance = const IdentityProvenance(
      source: 'community',
    );
    final rawProvenance = json['provenance'];
    if (rawProvenance is Map) {
      final map = Map<String, Object?>.from(rawProvenance);
      final source = map['source'];
      final updatedAt = map['updatedAt'];
      provenance = IdentityProvenance(
        source: source is String && source.isNotEmpty ? source : 'community',
        updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
      );
    }

    return CommunityAppMetadata(
      canonicalId: canonicalId,
      summary: textField('summary'),
      description: textField('description'),
      screenshots: screenshots,
      permissions: permissions,
      rating: rating,
      provenance: provenance,
    );
  }
}

/// Outcome of `StoreHost.refreshCommunityMetadata`
/// (docs/architecture/phase3-slice5.md §2).
///
/// Same shape as [CommunityRefreshResult]: a result object, not a
/// throw — refresh is an operator-initiated maintenance action, and
/// "all mirrors down" is an expected outcome, not an exceptional one.
///
/// Exported for future settings UI affordances (`store_host.dart`);
/// the refresh button itself is deferred (§6).
class CommunityMetadataRefreshResult {
  /// A mirror's `community-metadata` doc verified, was written to
  /// `~/.local/share/libreapp-center/identity-metadata.json`, and the
  /// in-memory metadata cache reloaded.
  const CommunityMetadataRefreshResult.ok({
    required this.entryCount,
    required this.generatedAt,
    required this.mirror,
    required this.keyId,
  }) : _kind = _RefreshKind.ok,
       reason = null,
       errorsByMirror = const {};

  /// No fetch was attempted: a gate failed. Never an error.
  const CommunityMetadataRefreshResult.skipped(this.reason)
    : _kind = _RefreshKind.skipped,
      entryCount = 0,
      generatedAt = null,
      mirror = null,
      keyId = null,
      errorsByMirror = const {};

  /// Every mirror failed: the previous metadata file (if any) and the
  /// in-memory cache are untouched.
  const CommunityMetadataRefreshResult.failed(this.errorsByMirror)
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

  /// Records in the verified doc. Set on [ok], 0 otherwise.
  final int entryCount;

  /// From the doc's `generatedAt` — informational only (staleness
  /// display), never a freshness gate. Set on [ok], null otherwise.
  final DateTime? generatedAt;

  /// The mirror URL whose doc won. Set on [ok], null otherwise.
  final String? mirror;

  /// The pinned curator keyId whose signature verified the winning
  /// doc. Set on [ok] (never null there), null otherwise.
  final String? keyId;

  /// Why no fetch was attempted. Set on [skipped], null otherwise.
  final String? reason;

  /// Per-mirror failure strings, in mirror order. Set on [failed],
  /// empty otherwise.
  final Map<String, String> errorsByMirror;

  @override
  String toString() => switch (_kind) {
    _RefreshKind.ok =>
      'CommunityMetadataRefreshResult.ok(records: $entryCount, '
          'mirror: $mirror)',
    _RefreshKind.skipped => 'CommunityMetadataRefreshResult.skipped($reason)',
    _RefreshKind.failed =>
      'CommunityMetadataRefreshResult.failed(${errorsByMirror.length} mirrors)',
  };
}

enum _RefreshKind { ok, skipped, failed }

/// Never-throws loader + alias-following lookup for the community
/// metadata doc (phase3-slice5.md §1–§2).
///
/// Host-internal plumbing: not exported from `store_host.dart`
/// (only [CommunityAppMetadata] and [CommunityMetadataRefreshResult]
/// are).
///
/// The doc is a single wholesale-replaced file — no seed, no local
/// overlay in v1 (metadata is display-only, so wholesale replace is
/// sufficient; a metadata overlay is §6 future work). ONLY the
/// post-verification file (written by
/// `StoreHost.refreshCommunityMetadata` after a full Ed25519 verify)
/// is ever read — unverified metadata is never displayed or returned.
class CommunityMetadataStore {
  /// Loads the metadata file(s). Never throws for I/O or JSON
  /// problems: missing/unreadable/unparseable files are skipped
  /// individually; worst case the caller gets an empty store.
  /// Malformed records are skipped and counted in [skippedRecords];
  /// the rest of the doc merges.
  ///
  /// A doc with `schemaVersion != 1` is skipped wholesale (same
  /// malformed-doc discipline as the identity index).
  Future<void> load({required List<String> paths}) async {
    final merged = <String, CommunityAppMetadata>{};
    var skipped = 0;
    for (final path in paths) {
      final doc = await _tryReadDoc(path);
      if (doc == null) continue;
      skipped += _applyDoc(doc, merged);
    }
    _entries = merged;
    _skippedRecords = skipped;
  }

  Map<String, CommunityAppMetadata> _entries = const {};
  int _skippedRecords = 0;

  /// Malformed records skipped by the last [load] (diagnostics).
  int get skippedRecords => _skippedRecords;

  /// Lookup following the identity index's alias chain — the same
  /// 8-hop rule as `IdentityResolver.entryFor`
  /// (`src/identity/identity_resolver.dart` → `IdentityIndex.entryFor`).
  ///
  /// Both sides are normalized through the forward chain: the query
  /// id is promoted (`entryFor(id)?.id ?? id`), and each metadata key
  /// is promoted the same way. So metadata keyed by a retired
  /// `homepage:` id is still found after the identity index promotes
  /// the entry to `appstream:` — and metadata keyed by the promoted
  /// id is found when queried with the retired id. When the index
  /// knows nothing about an id, the raw id string is the key. Null
  /// when nothing is recorded.
  ///
  /// The scan is O(records) per lookup — fine for a per-details-page
  /// call against a hundreds-strong metadata map, and it keeps the
  /// lookup on the public `entryFor` API (the index's alias map stays
  /// private to `store_contracts`).
  CommunityAppMetadata? entryFor(CanonicalAppId id, IdentityIndex index) {
    CanonicalAppId promote(CanonicalAppId candidate) =>
        index.entryFor(candidate)?.id ?? candidate;
    final promotedQuery = promote(id);
    final direct = _entries[promotedQuery.toString()];
    if (direct != null) return direct;
    for (final record in _entries.values) {
      if (promote(record.canonicalId) == promotedQuery) return record;
    }
    return null;
  }

  /// Merges one doc's records into [into]. Returns the number of
  /// records skipped as malformed.
  static int _applyDoc(
    Map<String, Object?> doc,
    Map<String, CommunityAppMetadata> into,
  ) {
    if (doc['schemaVersion'] != 1) return 0;
    final metadata = doc['metadata'];
    if (metadata is! List) return 0;
    var skipped = 0;
    for (final item in metadata) {
      // Strictness at parse, forgiveness at load: one bad record
      // never takes the doc down.
      if (item is! Map) {
        skipped++;
        continue;
      }
      try {
        final record = CommunityAppMetadata.fromJson(
          Map<String, Object?>.from(item),
        );
        into[record.canonicalId.toString()] = record;
      } on FormatException {
        skipped++;
      }
    }
    return skipped;
  }

  /// Reads one metadata file into a doc, or null when the file is
  /// missing, unreadable, or unparseable.
  static Future<Map<String, Object?>?> _tryReadDoc(String path) async {
    try {
      final raw = await File(path).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      return null;
    } on IOException {
      // Missing/unreadable file, path is a directory, permission
      // denied: all skip, none throw.
      return null;
    } on FormatException {
      // Unparseable JSON: skip.
      return null;
    }
  }
}
