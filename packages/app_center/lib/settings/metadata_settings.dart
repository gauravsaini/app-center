/// Providers and UI state for the Settings page's "Community metadata"
/// subsection (docs/architecture/phase3-slice6.md).
///
/// Mirrors `identity_settings.dart`'s shape deliberately (parallel
/// sealed state class, parallel notifier, parallel test seams) rather
/// than sharing a generic refresh abstraction: the two flows differ in
/// host method, trust seam, store, mirror provider, and honest-copy
/// keys, and sharing would tangle them (phase3-slice6.md §2).
///
/// No `backend_*` imports by design: this file sees only the host and
/// the contracts.
library;

import 'package:app_center/settings/community_metadata_refresh_store.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:store_host/store_host.dart';

/// Flips `phase3.metadata.enabled` and re-renders the details page
/// without a restart (phase3-slice6.md §3).
///
/// The host's [StoreHost.getCommunityMetadata] reads the flag at call
/// time and returns null before touching the cache when the flag is
/// off — so dropping the flag-derived provider and every cached
/// metadata lookup is enough; no host reload needed. The details page
/// stops watching [communityMetadataProvider] when
/// [metadataEnabledProvider] is false, so the family must be
/// invalidated explicitly (it holds no flag dependency of its own).
///
/// Top-level (not a widget closure) so widget tests drive the exact
/// production code path — same contract as `setIdentityEnabled`.
void setMetadataEnabled(WidgetRef ref, bool value) {
  final flags = ref.read(storeFlagsProvider);
  if (flags is MapFeatureFlags) {
    flags.setFlag('phase3.metadata.enabled', value);
  }
  ref.invalidate(metadataEnabledProvider);
  // Invalidating the family (no argument) drops every cached canonical
  // id: the next watch re-runs getCommunityMetadata with the new flag.
  ref.invalidate(communityMetadataProvider);
}

/// Operator-set metadata mirror list
/// (`phase3.community.metadata.mirrors`), parsed the same way the host
/// parses it (comma-separated, trimmed, non-empty). Display only — no
/// mirror editing UI: mirrors are an operator trust decision
/// (phase3-slice4.md §5).
final metadataMirrorsProvider = Provider<List<String>>(
  (ref) => ref
      .watch(storeFlagsProvider)
      .getString('phase3.community.metadata.mirrors')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false),
  name: 'metadataMirrorsProvider',
);

/// The UI-side persistence for metadata refresh attempts
/// (phase3-slice6.md §3). Overridable in tests with a temp dir.
final communityMetadataRefreshStoreProvider =
    Provider<CommunityMetadataRefreshStore>(
      (_) => CommunityMetadataRefreshStore(),
      name: 'communityMetadataRefreshStoreProvider',
    );

/// Test seam for the metadata fetch vehicle (phase3-slice6.md §3).
/// Null in production — the host then uses
/// [HttpCommunityIndexTransport]. Widget tests override with a
/// scripted [CommunityIndexTransport].
final metadataTransportOverrideProvider = Provider<CommunityIndexTransport?>(
  (_) => null,
  name: 'metadataTransportOverrideProvider',
);

/// Test seam for the metadata trust roots (phase3-slice6.md §3). Null
/// in production — the host then uses [CommunityTrustStore.bootstrap].
/// Widget tests override with an ephemeral trust store so a signed
/// metadata doc is verified through the REAL host, never against the
/// placeholder bootstrap key.
final metadataTrustOverrideProvider = Provider<CommunityTrustStore?>(
  (_) => null,
  name: 'metadataTrustOverrideProvider',
);

/// Display state of the community metadata refresh control.
///
/// `lastRecord` is the persisted record of the last attempt (loaded at
/// notifier build); every state carries it so the "last refresh" line
/// survives state transitions.
sealed class CommunityMetadataRefreshUiState {
  const CommunityMetadataRefreshUiState();

  CommunityMetadataRefreshRecord? get lastRecord => null;
}

/// Nothing attempted yet in this session (or since the last attempt
/// finished).
class CommunityMetadataRefreshIdle extends CommunityMetadataRefreshUiState {
  const CommunityMetadataRefreshIdle({this.lastRecord});

  @override
  final CommunityMetadataRefreshRecord? lastRecord;
}

/// A refresh is in flight. Indeterminate by design: the host exposes a
/// single Future with no per-phase progress, so the UI must not fake
/// "downloading 42%" (phase3-slice4.md §2, phase3-slice6.md §2).
class CommunityMetadataRefreshChecking extends CommunityMetadataRefreshUiState {
  const CommunityMetadataRefreshChecking({this.lastRecord});

  @override
  final CommunityMetadataRefreshRecord? lastRecord;
}

/// A mirror's metadata doc verified and was installed.
class CommunityMetadataRefreshUpToDate extends CommunityMetadataRefreshUiState {
  const CommunityMetadataRefreshUpToDate({
    required this.entryCount,
    required this.generatedAt,
    required this.mirror,
    this.keyId,
    this.lastRecord,
  });

  /// Metadata records in the verified doc.
  final int entryCount;

  /// The doc's `generatedAt` — informational staleness display, never a
  /// freshness gate (host result-type contract).
  final DateTime? generatedAt;

  /// The mirror URL whose doc won.
  final String? mirror;

  /// The pinned curator key whose signature verified the doc. Carried
  /// on the host's ok result (never null there). Shown as
  /// "signature valid — key `keyId`", never "verified safe".
  final String? keyId;

  @override
  final CommunityMetadataRefreshRecord? lastRecord;
}

/// Every mirror failed. The previous metadata file (if any) and the
/// in-memory cache are untouched (host contract).
class CommunityMetadataRefreshFailed extends CommunityMetadataRefreshUiState {
  const CommunityMetadataRefreshFailed({
    required this.errorsByMirror,
    this.lastRecord,
  });

  /// Per-mirror failure strings, in mirror order. Message-only by host
  /// contract — safe to display verbatim.
  final Map<String, String> errorsByMirror;

  @override
  final CommunityMetadataRefreshRecord? lastRecord;
}

/// No fetch was attempted: a gate failed (identity/metadata/community
/// disabled, metadata mirrors empty, HOME unset). Never an error —
/// this is the expected state for a fresh install.
class CommunityMetadataRefreshSkipped extends CommunityMetadataRefreshUiState {
  const CommunityMetadataRefreshSkipped({
    required this.reason,
    this.lastRecord,
  });

  final String reason;

  @override
  final CommunityMetadataRefreshRecord? lastRecord;
}

/// Drives the metadata refresh button through
/// `idle → checking → up-to-date | failed | skipped`.
///
/// Never throws: "all mirrors down" is a `failed` state, and a
/// defensive catch maps any unexpected throw to `failed` too.
class CommunityMetadataRefreshNotifier
    extends Notifier<CommunityMetadataRefreshUiState> {
  @override
  CommunityMetadataRefreshUiState build() {
    _loadLastRecord();
    return const CommunityMetadataRefreshIdle();
  }

  Future<void> _loadLastRecord() async {
    final record = await ref.read(communityMetadataRefreshStoreProvider).load();
    if (record != null) {
      state = CommunityMetadataRefreshIdle(lastRecord: record);
    }
  }

  /// Test seam: seeds the display state directly (up-to-date rendering
  /// tests don't need a host round-trip).
  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void debugSetState(CommunityMetadataRefreshUiState value) => state = value;

  Future<void> refresh() async {
    if (state is CommunityMetadataRefreshChecking) return;
    final previous = state.lastRecord;
    state = CommunityMetadataRefreshChecking(lastRecord: previous);
    final store = ref.read(communityMetadataRefreshStoreProvider);
    final attemptedAt = DateTime.now().toUtc();
    try {
      final host = ref.read(storeHostProvider);
      final result = await host.refreshCommunityMetadata(
        transport: ref.read(metadataTransportOverrideProvider),
        trust:
            ref.read(metadataTrustOverrideProvider) ??
            CommunityTrustStore.bootstrap,
      );
      if (result.isOk) {
        final record = CommunityMetadataRefreshRecord(
          attemptedAt: attemptedAt,
          succeededAt: attemptedAt,
          mirror: result.mirror,
          entryCount: result.entryCount,
        );
        await store.save(record);
        state = CommunityMetadataRefreshUpToDate(
          entryCount: result.entryCount,
          generatedAt: result.generatedAt,
          mirror: result.mirror,
          keyId: result.keyId,
          lastRecord: record,
        );
      } else if (result.isSkipped) {
        // A skip is not a success — keep the last success's fields so
        // the UI still shows when metadata was last good.
        await store.save(
          CommunityMetadataRefreshRecord(
            attemptedAt: attemptedAt,
            succeededAt: previous?.succeededAt,
            mirror: previous?.mirror,
            entryCount: previous?.entryCount,
          ),
        );
        state = CommunityMetadataRefreshSkipped(
          reason: result.reason ?? '',
          lastRecord: await store.load(),
        );
      } else {
        // A failure must not erase the last success — preserve its
        // fields, only the attempt timestamp is new.
        await store.save(
          CommunityMetadataRefreshRecord(
            attemptedAt: attemptedAt,
            succeededAt: previous?.succeededAt,
            mirror: previous?.mirror,
            entryCount: previous?.entryCount,
          ),
        );
        state = CommunityMetadataRefreshFailed(
          errorsByMirror: Map<String, String>.from(result.errorsByMirror),
          lastRecord: await store.load(),
        );
      }
    } on Object catch (e) {
      // The host promises never to throw; if that ever regresses the
      // UI still degrades to a failed state instead of crashing.
      // Preserve the last success's fields here too.
      await store.save(
        CommunityMetadataRefreshRecord(
          attemptedAt: attemptedAt,
          succeededAt: previous?.succeededAt,
          mirror: previous?.mirror,
          entryCount: previous?.entryCount,
        ),
      );
      state = CommunityMetadataRefreshFailed(
        errorsByMirror: {'refresh': '$e'},
        lastRecord: await store.load(),
      );
    }
  }
}

final communityMetadataRefreshStateProvider =
    NotifierProvider<
      CommunityMetadataRefreshNotifier,
      CommunityMetadataRefreshUiState
    >(
      CommunityMetadataRefreshNotifier.new,
      name: 'communityMetadataRefreshStateProvider',
    );

/// Human-readable one-line summary of a metadata refresh state, for
/// tests and debugging. UI copy itself lives in the arb (all strings
/// via app_en.arb keys only).
String describeMetadataRefreshState(
  CommunityMetadataRefreshUiState state,
) => switch (state) {
  CommunityMetadataRefreshChecking() => 'checking',
  CommunityMetadataRefreshUpToDate() => 'up-to-date',
  CommunityMetadataRefreshFailed() => 'failed',
  CommunityMetadataRefreshSkipped() => 'skipped',
  CommunityMetadataRefreshIdle() => 'idle',
};
