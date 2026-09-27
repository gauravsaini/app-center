/// Providers and UI state for the Settings page's "App identity" section
/// (docs/architecture/phase3-slice4.md).
///
/// No `backend_*` imports by design: this file sees only the host and
/// the contracts.
library;

import 'package:app_center/manage/unified_installed_provider.dart';
import 'package:app_center/search/search_provider.dart';
import 'package:app_center/settings/community_refresh_store.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:store_host/store_host.dart';

/// Flips `phase3.identity.enabled` and re-resolves the UI without a
/// restart (phase3-slice4.md §3).
///
/// `MapFeatureFlags.setFlag` mutates in place — Riverpod can't see the
/// mutation — so the providers that cache flag-derived or host-derived
/// data are invalidated explicitly. The host itself reads the flag at
/// call time (verified in code, phase3-slice4.md "Runtime identity
/// toggle"), so re-running the search/installed providers re-fans-out
/// with the new flag value and merged cards appear (or disappear).
///
/// Top-level (not a widget closure) so widget tests drive the exact
/// production code path.
void setIdentityEnabled(WidgetRef ref, bool value) {
  final flags = ref.read(storeFlagsProvider);
  if (flags is MapFeatureFlags) {
    flags.setFlag('phase3.identity.enabled', value);
  }
  ref.invalidate(identityEnabledProvider);
  // Invalidating the family (no argument) drops every cached query:
  // the next watch re-runs StoreHost.search with the new flag value.
  ref.invalidate(unifiedSearchProvider);
  ref.invalidate(unifiedInstalledResultProvider);
}

/// Flips `phase3.community.enabled` (opt-in to community distribution).
/// Same invalidation shape as [setIdentityEnabled]: the flag is read at
/// refresh time, so only the flag-derived providers need invalidation.
void setCommunityEnabled(WidgetRef ref, bool value) {
  final flags = ref.read(storeFlagsProvider);
  if (flags is MapFeatureFlags) {
    flags.setFlag('phase3.community.enabled', value);
  }
  ref.invalidate(communityEnabledProvider);
  ref.invalidate(communityMirrorsProvider);
}

/// Kill switch for the community index distribution
/// (`phase3.community.enabled`), following the [identityEnabledProvider]
/// pattern: a sync flag read, no async probing.
final communityEnabledProvider = Provider<bool>(
  (ref) => ref.watch(storeFlagsProvider).isEnabled('phase3.community.enabled'),
  name: 'communityEnabledProvider',
);

/// Operator-set mirror list (`phase3.community.mirrors`), parsed the
/// same way the host parses it (comma-separated, trimmed, non-empty).
/// Display only — this slice has no mirror editing UI (phase3-slice4.md
/// §5: mirrors are an operator trust decision).
final communityMirrorsProvider = Provider<List<String>>(
  (ref) => ref
      .watch(storeFlagsProvider)
      .getString('phase3.community.mirrors')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false),
  name: 'communityMirrorsProvider',
);

/// The UI-side persistence for refresh attempts
/// (phase3-slice4.md §4). Overridable in tests with a temp dir.
final communityRefreshStoreProvider = Provider<CommunityRefreshStore>(
  (_) => CommunityRefreshStore(),
  name: 'communityRefreshStoreProvider',
);

/// Test seam for the community fetch vehicle
/// (docs/architecture/phase3-slice4.md §6). Null in production — the
/// host then uses [HttpCommunityIndexTransport]. Widget tests override
/// with a scripted [CommunityIndexTransport].
final communityTransportOverrideProvider = Provider<CommunityIndexTransport?>(
  (_) => null,
  name: 'communityTransportOverrideProvider',
);

/// Display state of the community index refresh control.
///
/// `lastRecord` is the persisted record of the last attempt (loaded at
/// notifier build); every state carries it so the "last refresh" line
/// survives state transitions.
sealed class CommunityRefreshUiState {
  const CommunityRefreshUiState();

  CommunityRefreshRecord? get lastRecord => null;
}

/// Nothing attempted yet in this session (or since the last attempt
/// finished).
class CommunityRefreshIdle extends CommunityRefreshUiState {
  const CommunityRefreshIdle({this.lastRecord});

  @override
  final CommunityRefreshRecord? lastRecord;
}

/// A refresh is in flight. Indeterminate by design: the host exposes a
/// single Future with no per-phase progress, so the UI must not fake
/// "downloading 42%" (phase3-slice4.md §2).
class CommunityRefreshChecking extends CommunityRefreshUiState {
  const CommunityRefreshChecking({this.lastRecord});

  @override
  final CommunityRefreshRecord? lastRecord;
}

/// A mirror's doc verified and was installed.
class CommunityRefreshUpToDate extends CommunityRefreshUiState {
  const CommunityRefreshUpToDate({
    required this.entryCount,
    required this.generatedAt,
    required this.mirror,
    this.keyId,
    this.lastRecord,
  });

  /// Entries in the verified doc.
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
  final CommunityRefreshRecord? lastRecord;
}

/// Every mirror failed. The previous community file (if any) and the
/// in-memory index are untouched (host contract).
class CommunityRefreshFailed extends CommunityRefreshUiState {
  const CommunityRefreshFailed({required this.errorsByMirror, this.lastRecord});

  /// Per-mirror failure strings, in mirror order. Message-only by host
  /// contract — safe to display verbatim.
  final Map<String, String> errorsByMirror;

  @override
  final CommunityRefreshRecord? lastRecord;
}

/// No fetch was attempted: a gate failed (identity/community disabled,
/// mirrors empty, HOME unset). Never an error — this is the expected
/// state for a fresh install.
class CommunityRefreshSkipped extends CommunityRefreshUiState {
  const CommunityRefreshSkipped({required this.reason, this.lastRecord});

  final String reason;

  @override
  final CommunityRefreshRecord? lastRecord;
}

/// Drives the refresh button through
/// `idle → checking → up-to-date | failed | skipped`.
///
/// Never throws: "all mirrors down" is a `failed` state, and a
/// defensive catch maps any unexpected throw to `failed` too.
class CommunityRefreshNotifier extends Notifier<CommunityRefreshUiState> {
  @override
  CommunityRefreshUiState build() {
    _loadLastRecord();
    return const CommunityRefreshIdle();
  }

  Future<void> _loadLastRecord() async {
    final record = await ref.read(communityRefreshStoreProvider).load();
    if (record != null) {
      state = CommunityRefreshIdle(lastRecord: record);
    }
  }

  /// Test seam: seeds the display state directly (up-to-date rendering
  /// tests don't need a host round-trip).
  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void debugSetState(CommunityRefreshUiState value) => state = value;

  Future<void> refresh() async {
    if (state is CommunityRefreshChecking) return;
    final previous = state.lastRecord;
    state = CommunityRefreshChecking(lastRecord: previous);
    final store = ref.read(communityRefreshStoreProvider);
    final attemptedAt = DateTime.now().toUtc();
    try {
      final host = ref.read(storeHostProvider);
      final result = await host.refreshCommunityIndex(
        transport: ref.read(communityTransportOverrideProvider),
      );
      if (result.isOk) {
        final record = CommunityRefreshRecord(
          attemptedAt: attemptedAt,
          succeededAt: attemptedAt,
          mirror: result.mirror,
          entryCount: result.entryCount,
        );
        await store.save(record);
        state = CommunityRefreshUpToDate(
          entryCount: result.entryCount,
          generatedAt: result.generatedAt,
          mirror: result.mirror,
          keyId: result.keyId,
          lastRecord: record,
        );
      } else if (result.isSkipped) {
        await store.save(CommunityRefreshRecord(attemptedAt: attemptedAt));
        state = CommunityRefreshSkipped(
          reason: result.reason ?? '',
          lastRecord: await store.load(),
        );
      } else {
        await store.save(CommunityRefreshRecord(attemptedAt: attemptedAt));
        state = CommunityRefreshFailed(
          errorsByMirror: Map<String, String>.from(result.errorsByMirror),
          lastRecord: await store.load(),
        );
      }
    } on Object catch (e) {
      // The host promises never to throw; if that ever regresses the
      // UI still degrades to a failed state instead of crashing.
      await store.save(CommunityRefreshRecord(attemptedAt: attemptedAt));
      state = CommunityRefreshFailed(
        errorsByMirror: {'refresh': '$e'},
        lastRecord: await store.load(),
      );
    }
  }
}

final communityRefreshStateProvider =
    NotifierProvider<CommunityRefreshNotifier, CommunityRefreshUiState>(
      CommunityRefreshNotifier.new,
      name: 'communityRefreshStateProvider',
    );

/// Human-readable one-line summary of a refresh state, for tests and
/// debugging. UI copy itself lives in the arb (all strings via
/// app_en.arb keys only).
String describeRefreshState(CommunityRefreshUiState state) => switch (state) {
  CommunityRefreshChecking() => 'checking',
  CommunityRefreshUpToDate() => 'up-to-date',
  CommunityRefreshFailed() => 'failed',
  CommunityRefreshSkipped() => 'skipped',
  CommunityRefreshIdle() => 'idle',
};
