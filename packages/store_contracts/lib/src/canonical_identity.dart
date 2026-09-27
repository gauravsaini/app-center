/// Canonical identity types + [IdentityIndex] (Phase 3 identity, slice 1).
///
/// Pure Dart — no dart:io, no Flutter. Implements
/// `docs/architecture/phase3-identity-lld.md` §2 and §4.
///
/// Strictness lives at the parse layer ([CanonicalAppId.parse],
/// [CanonicalEntry.fromJson]); forgiveness lives at the load layer
/// ([IdentityIndex.fromJsonDocs] skips malformed docs and counts them).
library;

import 'dart:convert';

/// Scheme of a [CanonicalAppId]. Deliberately two: there is no `name:`
/// scheme — a bare name is never an identity.
enum CanonicalIdScheme { appstream, homepage }

/// A cross-format app identity: `scheme:value`, e.g.
/// `appstream:org.mozilla.firefox` or `homepage:mozilla.org/firefox`.
///
/// Value type: const-constructible, == / hashCode on (scheme, value).
/// Parsing is strict: NO value normalization at parse time (silent
/// normalization hides data bugs). Normalization happens once, at
/// index-build time ([normalizeHomepage]).
class CanonicalAppId {
  const CanonicalAppId(this.scheme, this.value);

  final CanonicalIdScheme scheme;

  /// e.g. `org.mozilla.firefox`, `mozilla.org/firefox`.
  final String value;

  /// Parses `'appstream:org.mozilla.firefox'`.
  /// Throws [FormatException] on missing colon, unknown scheme,
  /// empty value, or whitespace in the value.
  factory CanonicalAppId.parse(String s) {
    final colon = s.indexOf(':');
    if (colon < 0) {
      throw FormatException('canonical id has no scheme separator', s);
    }
    final scheme = switch (s.substring(0, colon)) {
      'appstream' => CanonicalIdScheme.appstream,
      'homepage' => CanonicalIdScheme.homepage,
      _ => throw FormatException('unknown canonical id scheme', s),
    };
    final value = s.substring(colon + 1);
    if (value.isEmpty) {
      throw FormatException('canonical id value is empty', s);
    }
    if (value.contains(RegExp(r'\s'))) {
      throw FormatException('canonical id value contains whitespace', s);
    }
    return CanonicalAppId(scheme, value);
  }

  /// `'appstream:org.mozilla.firefox'`. Round-trips through [parse].
  @override
  String toString() => '${scheme.name}:$value';

  @override
  bool operator ==(Object other) =>
      other is CanonicalAppId && other.scheme == scheme && other.value == value;

  @override
  int get hashCode => Object.hash(scheme, value);
}

/// Cross-format evidence a backend reports for one app.
///
/// Both fields nullable: backends report what they have. Slice 1: no
/// backend reports signals yet (slice 2); the resolver accepts them and
/// tests cover the paths with fixtures.
class IdentitySignal {
  const IdentitySignal({this.appstreamId, this.homepageUrl});

  /// Raw AppStream component id; matched verbatim against entry
  /// `appstreamIds`.
  final String? appstreamId;

  /// Raw homepage URL; normalized with [normalizeHomepage] before matching.
  final String? homepageUrl;
}

/// Where one [CanonicalEntry]'s editorial content came from.
class IdentityProvenance {
  const IdentityProvenance({required this.source, this.updatedAt});

  /// `'seed'` | `'local'` | `'community'` | ...
  final String source;

  final DateTime? updatedAt;
}

/// One curated canonical app: its identity, the signals that prove it,
/// and the per-backend identity lookup keys that map to it.
class CanonicalEntry {
  const CanonicalEntry({
    required this.id,
    this.displayName,
    this.appstreamIds = const [],
    this.homepages = const [],
    this.backendKeys = const {},
    this.provenance = const IdentityProvenance(source: 'unknown'),
  });

  final CanonicalAppId id;
  final String? displayName;

  /// AppStream component ids known for this app.
  final List<String> appstreamIds;

  /// Homepage keys, stored NORMALIZED (see [normalizeHomepage]).
  final List<String> homepages;

  /// backendId -> identity lookup keys (NOT raw native ids — see
  /// [StoreBackend.identityLookupKey]: arch- and version-agnostic).
  final Map<String, List<String>> backendKeys;

  final IdentityProvenance provenance;

  /// Canonical JSON (LLD §4): exact key order
  /// `canonicalId, displayName?, appstreamIds, homepages, backends,
  /// provenance`; lists sorted; `displayName`/`updatedAt` omitted when
  /// null; timestamps UTC ISO-8601 with `Z`.
  Map<String, Object?> toJson() {
    final backends = <String, Object?>{
      for (final backendId in backendKeys.keys.toList()..sort())
        backendId: (backendKeys[backendId]!.toList()..sort()),
    };
    final provenanceJson = <String, Object?>{
      'source': provenance.source,
      if (provenance.updatedAt != null)
        'updatedAt': provenance.updatedAt!.toUtc().toIso8601String(),
    };
    return {
      'canonicalId': id.toString(),
      if (displayName != null) 'displayName': displayName,
      'appstreamIds': (appstreamIds.toList()..sort()),
      'homepages': (homepages.toList()..sort()),
      'backends': backends,
      'provenance': provenanceJson,
    };
  }

  /// Strict per-entry parse: bad shape → [FormatException]. Unknown
  /// fields are ignored (forward compatibility).
  factory CanonicalEntry.fromJson(Map<String, Object?> json) {
    final rawId = json['canonicalId'];
    if (rawId is! String) {
      throw FormatException(
        'entry is missing a string canonicalId',
        jsonEncode(json),
      );
    }
    final id = CanonicalAppId.parse(rawId);

    final displayName = json['displayName'];
    if (displayName != null && displayName is! String) {
      throw FormatException(
        'entry displayName is not a string',
        jsonEncode(json),
      );
    }

    final appstreamIds = _stringList(json, 'appstreamIds');
    final homepages = _stringList(json, 'homepages');

    final backendKeys = <String, List<String>>{};
    final rawBackends = json['backends'];
    if (rawBackends != null) {
      if (rawBackends is! Map ||
          rawBackends.entries.any(
            (e) =>
                e.key is! String ||
                e.value is! List ||
                (e.value as List).any((k) => k is! String),
          )) {
        throw FormatException(
          'entry backends is not a map of string lists',
          jsonEncode(json),
        );
      }
      for (final e in rawBackends.entries) {
        backendKeys[e.key as String] = List<String>.of(
          (e.value as List).cast<String>(),
        );
      }
    }

    var provenance = const IdentityProvenance(source: 'unknown');
    final rawProvenance = json['provenance'];
    if (rawProvenance != null) {
      if (rawProvenance is! Map) {
        throw FormatException(
          'entry provenance is not an object',
          jsonEncode(json),
        );
      }
      final source = rawProvenance['source'];
      if (source is! String) {
        throw FormatException(
          'entry provenance.source is not a string',
          jsonEncode(json),
        );
      }
      DateTime? updatedAt;
      final rawUpdatedAt = rawProvenance['updatedAt'];
      if (rawUpdatedAt != null) {
        if (rawUpdatedAt is! String ||
            DateTime.tryParse(rawUpdatedAt) == null) {
          throw FormatException(
            'entry provenance.updatedAt is not ISO-8601',
            jsonEncode(json),
          );
        }
        updatedAt = DateTime.parse(rawUpdatedAt);
      }
      provenance = IdentityProvenance(source: source, updatedAt: updatedAt);
    }

    return CanonicalEntry(
      id: id,
      displayName: displayName as String?,
      appstreamIds: appstreamIds,
      homepages: homepages,
      backendKeys: backendKeys,
      provenance: provenance,
    );
  }

  static List<String> _stringList(Map<String, Object?> json, String key) {
    final raw = json[key];
    if (raw == null) return const [];
    if (raw is! List || raw.any((e) => e is! String)) {
      throw FormatException(
        'entry $key is not a list of strings',
        jsonEncode(json),
      );
    }
    return List<String>.of(raw.cast<String>());
  }
}

/// Normalizes a homepage URL into a stable identity key.
///
/// Total function: never throws. Garbage in → a stable garbage key that
/// simply never matches. No URL-decoding: encoded forms are distinct
/// keys; curated data uses plain forms.
///
/// Algorithm: trim → strip scheme (`^[a-zA-Z][a-zA-Z0-9+.-]*://`) → cut
/// at first `?`/`#` → split host/path at first `/` → host lowercase, strip
/// one leading `www.` → strip trailing `/` from path → path empty → host
/// only, else `host/path`.
///
/// Examples:
/// - `https://www.mozilla.org/en-US/firefox/` → `mozilla.org/en-US/firefox`
/// - `http://videolan.org/vlc/` → `videolan.org/vlc`
String normalizeHomepage(String url) {
  var s = url.trim();
  final scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').firstMatch(s);
  if (scheme != null) s = s.substring(scheme.end);
  final queryOrFragment = s.indexOf(RegExp('[?#]'));
  if (queryOrFragment >= 0) s = s.substring(0, queryOrFragment);
  final slash = s.indexOf('/');
  final rawHost = slash < 0 ? s : s.substring(0, slash);
  var path = slash < 0 ? '' : s.substring(slash + 1);
  var host = rawHost.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path.isEmpty ? host : '$host/$path';
}

/// Pure in-memory identity index built from layered JSON docs. No I/O.
///
/// Docs are processed lowest-priority-first; per LLD §2.6 a later doc's
/// entry REPLACES scalar fields (`displayName`, `provenance`) and UNIONS
/// signal lists (`appstreamIds`, `homepages`, per-backend key lists —
/// deduped, order-preserving with existing entries first); `aliases`
/// union with the later doc winning on key conflict.
class IdentityIndex {
  IdentityIndex._(
    this._entries,
    this._aliases,
    this._byBackendKey,
    this._byAppstream,
    this._byHomepage, {
    required this.skippedDocs,
  });

  /// Builds from layered docs, lowest priority FIRST.
  ///
  /// Malformed docs are SKIPPED (a corrupt index must never crash the
  /// store) and counted in [skippedDocs]. A doc is malformed when:
  /// `schemaVersion != 1`, `entries` is not a list, any entry fails
  /// [CanonicalEntry.fromJson], or any alias key/value is not a parseable
  /// [CanonicalAppId]. Doc application is atomic: a skipped doc changes
  /// nothing (entries parsed fully before any merge).
  factory IdentityIndex.fromJsonDocs(List<Map<String, Object?>> docs) {
    final entries = <String, CanonicalEntry>{};
    final aliases = <String, String>{};
    var skipped = 0;
    for (final doc in docs) {
      if (_applyDoc(doc, entries, aliases)) continue;
      skipped++;
    }
    // Derive the O(1) lookup maps from the merged entries.
    final byBackendKey = <String, String>{};
    final byAppstream = <String, String>{};
    final byHomepage = <String, String>{};
    for (final key in entries.keys) {
      final entry = entries[key]!;
      for (final backend in entry.backendKeys.entries) {
        for (final lookup in backend.value) {
          if (lookup.isEmpty) continue; // index build drops empty keys
          byBackendKey['${backend.key}:$lookup'] = key;
        }
      }
      for (final appstreamId in entry.appstreamIds) {
        byAppstream[appstreamId] = key;
      }
      for (final homepage in entry.homepages) {
        // Stored normalized per schema; normalize again defensively —
        // idempotent on compliant data, forgiving on the rest.
        byHomepage[normalizeHomepage(homepage)] = key;
      }
    }
    return IdentityIndex._(
      Map.unmodifiable(entries),
      Map.unmodifiable(aliases),
      Map.unmodifiable(byBackendKey),
      Map.unmodifiable(byAppstream),
      Map.unmodifiable(byHomepage),
      skippedDocs: skipped,
    );
  }

  /// Empty index: everything resolves to null.
  factory IdentityIndex.empty() =>
      IdentityIndex._({}, {}, {}, {}, {}, skippedDocs: 0);

  /// Number of docs skipped as malformed (diagnostics).
  final int skippedDocs;

  int get entryCount => _entries.length;

  final Map<String, CanonicalEntry> _entries;
  final Map<String, String> _aliases;
  final Map<String, String> _byBackendKey;
  final Map<String, String> _byAppstream;
  final Map<String, String> _byHomepage;

  /// Resolution order (LLD §2.7): curated backend-key → AppStream signal
  /// → homepage signal → null (unresolved). Deterministic, total, O(1)
  /// per step. Conflicts never throw: the ranking decides.
  CanonicalAppId? resolve(
    String backendId,
    String lookupKey, [
    IdentitySignal? signals,
  ]) {
    if (lookupKey.isNotEmpty) {
      final hit = _byBackendKey['$backendId:$lookupKey'];
      if (hit != null) return CanonicalAppId.parse(hit);
    }
    final appstreamId = signals?.appstreamId;
    if (appstreamId != null) {
      final hit = _byAppstream[appstreamId];
      if (hit != null) return CanonicalAppId.parse(hit);
    }
    final homepageUrl = signals?.homepageUrl;
    if (homepageUrl != null) {
      final hit = _byHomepage[normalizeHomepage(homepageUrl)];
      if (hit != null) return CanonicalAppId.parse(hit);
    }
    return null;
  }

  /// Follows aliases (canonical-id migration). Null when unknown.
  /// Terminates on cycles: after 8 hops the chain is treated as broken
  /// and null is returned.
  CanonicalEntry? entryFor(CanonicalAppId id) {
    var key = id.toString();
    for (var hop = 0; hop < 8; hop++) {
      final next = _aliases[key];
      if (next == null) break;
      key = next;
    }
    if (_aliases.containsKey(key)) return null; // cycle or >8-hop chain
    return _entries[key];
  }

  /// Canonical JSON (LLD §4): exact top-level key order
  /// `schemaVersion, generatedAt, source, entries, aliases`; entries
  /// sorted by canonical id; alias keys sorted. `generatedAt` is UTC
  /// ISO-8601 with `Z`. Round-trips through [fromJsonDocs] (the merged
  /// document is emitted as a single layer with `source: 'merged'`).
  Map<String, Object?> toJson() {
    final sortedKeys = _entries.keys.toList()..sort();
    return {
      'schemaVersion': 1,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'source': 'merged',
      'entries': [for (final key in sortedKeys) _entries[key]!.toJson()],
      'aliases': {
        for (final key in _aliases.keys.toList()..sort()) key: _aliases[key],
      },
    };
  }

  /// Parses and merges one doc into [entries]/[aliases]. Returns false
  /// when the doc is malformed (caller counts it as skipped).
  static bool _applyDoc(
    Map<String, Object?> doc,
    Map<String, CanonicalEntry> entries,
    Map<String, String> aliases,
  ) {
    if (doc['schemaVersion'] != 1) return false;
    final rawEntries = doc['entries'];
    if (rawEntries is! List) return false;
    // Parse everything first: atomic application, one bad entry
    // rejects the whole doc.
    final parsed = <CanonicalEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map<String, Object?>) return false;
      try {
        parsed.add(CanonicalEntry.fromJson(raw));
      } on FormatException {
        return false;
      }
    }
    final parsedAliases = <String, String>{};
    final rawAliases = doc['aliases'];
    if (rawAliases != null) {
      if (rawAliases is! Map) return false;
      for (final alias in rawAliases.entries) {
        if (alias.key is! String || alias.value is! String) return false;
        try {
          final from = CanonicalAppId.parse(alias.key as String).toString();
          final to = CanonicalAppId.parse(alias.value as String).toString();
          parsedAliases[from] = to;
        } on FormatException {
          return false;
        }
      }
    }
    for (final entry in parsed) {
      final key = entry.id.toString();
      final existing = entries[key];
      entries[key] = existing == null ? entry : _mergeEntries(existing, entry);
    }
    aliases.addAll(parsedAliases);
    return true;
  }

  /// Later doc ([higher]) wins on scalars; signal lists union with
  /// existing-first ordering. Empty backend keys are dropped.
  static CanonicalEntry _mergeEntries(
    CanonicalEntry existing,
    CanonicalEntry higher,
  ) {
    List<String> union(List<String> a, List<String> b) {
      final out = a.where((s) => s.isNotEmpty).toList();
      for (final s in b) {
        if (s.isNotEmpty && !out.contains(s)) out.add(s);
      }
      return out;
    }

    final backendKeys = <String, List<String>>{};
    for (final e in existing.backendKeys.entries) {
      backendKeys[e.key] = e.value.where((k) => k.isNotEmpty).toList();
    }
    for (final e in higher.backendKeys.entries) {
      final list = backendKeys.putIfAbsent(e.key, () => <String>[]);
      for (final k in e.value) {
        if (k.isNotEmpty && !list.contains(k)) list.add(k);
      }
    }
    return CanonicalEntry(
      id: existing.id,
      displayName: higher.displayName,
      appstreamIds: union(existing.appstreamIds, higher.appstreamIds),
      homepages: union(existing.homepages, higher.homepages),
      backendKeys: backendKeys,
      provenance: higher.provenance,
    );
  }
}
