/// Unified updates section for the updates strangler-fig slice.
///
/// Rendered in place of the legacy updates sections (snap/deb update
/// models + update-all action) when the `pages.updates.unified` flag is
/// on. Reads [unifiedUpdatesProvider] (`StoreHost.checkUpdates()`) and
/// renders one row per [UpdateInfo]: name, `fromVersion → toVersion`,
/// and a backend badge (same badge pattern as [UnifiedManagePage]).
/// Versions and sizes may be null — rows render without them.
///
/// Update-all enqueues one [OperationKind.update] per [UpdateInfo]
/// through [StoreHost.enqueue], which dedupes per [AppIdentity]: a
/// repeat press while updates are in flight returns the existing
/// handles instead of double-enqueueing. A backend disappearing
/// between check and enqueue surfaces as [BackendUnavailableException]
/// per item — recorded and shown inline, never aborting the remaining
/// updates. After the batch reaches terminal state the provider is
/// invalidated so the list refreshes.
///
/// No `backend_*` import by design: this file sees only the host, the
/// contracts, and app_center internals.
library;

import 'package:app_center/error/error.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/layout.dart';
import 'package:app_center/manage/unified_manage_page.dart';
import 'package:app_center/manage/unified_updates_provider.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:app_center/widgets/operation_inflight_controls.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';
import 'package:ubuntu_widgets/ubuntu_widgets.dart';
import 'package:yaru/yaru.dart';

/// Updates list sourced from the unified store.
///
/// Shown only when `pages.updates.unified` is on; the legacy updates
/// sections stay the default until this view reaches parity. Designed
/// to sit inside a sliver list on the Manage page.
class UnifiedUpdatesSection extends ConsumerStatefulWidget {
  const UnifiedUpdatesSection({super.key});

  @override
  ConsumerState<UnifiedUpdatesSection> createState() =>
      _UnifiedUpdatesSectionState();
}

class _UnifiedUpdatesSectionState extends ConsumerState<UnifiedUpdatesSection> {
  bool _updatingAll = false;
  String? _updateAllError;

  /// Enqueues one host update per [UpdateInfo], waits for the batch to
  /// reach terminal state, then refreshes the list.
  ///
  /// Routing (verified against the host and all three backends):
  /// [StoreHost.enqueue] dedupes per [AppIdentity] and throws
  /// [BackendUnavailableException] when the owning backend is missing
  /// or flag-disabled; every backend advertising
  /// [BackendCapability.update] (snap, deb, flatpak) implements
  /// `update(AppIdentity)` by refreshing that single native id
  /// (`snap refresh <name>`, PackageKit update of `<name>`,
  /// `flatpak update -y <ref>`). Note flatpak's `checkUpdates()` is
  /// not wired (returns `[]`), so update-all effectively covers
  /// snap+deb today.
  Future<void> _updateAll(List<UpdateInfo> updates) async {
    if (_updatingAll || updates.isEmpty) return;
    setState(() {
      _updatingAll = true;
      _updateAllError = null;
    });
    final host = ref.read(storeHostProvider);
    final failures = <String>[];
    for (final info in updates) {
      try {
        final handle = await host.enqueue(
          OperationKind.update,
          info.identity,
        );
        await _awaitTerminal(handle);
      } on Exception catch (e) {
        // One failed start never aborts the remaining updates.
        failures.add('${info.name}: $e');
      }
    }
    ref.invalidate(unifiedUpdatesProvider);
    if (mounted) {
      setState(() {
        _updatingAll = false;
        _updateAllError = failures.isEmpty ? null : failures.join('\n');
      });
    }
  }

  /// Waits for a handle to reach a terminal state. The handle's state
  /// stream is broadcast with no replay, so an already-terminal handle
  /// (e.g. returned by the host's per-identity dedupe) is checked via
  /// [OperationHandle.current] first — otherwise `first` would hang.
  static Future<void> _awaitTerminal(OperationHandle handle) async {
    if (handle.current.isTerminal) return;
    try {
      await handle.state.where((s) => s.isTerminal).first;
    } on Exception {
      // Stream errors/early close: the op is over as far as the UI cares.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final updates = ref.watch(unifiedUpdatesProvider);
    final count = updates.valueOrNull?.length ?? 0;

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  l10n.managePageUpdatesAvailable(count),
                  style: textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              PushButton.elevated(
                onPressed: _updatingAll || count == 0
                    ? null
                    : () => _updateAll(updates.valueOrNull ?? const []),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(YaruIcons.download),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _updatingAll
                            ? l10n.snapActionUpdatingLabel
                            : l10n.managePageUpdateAllLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: kMarginLarge),
          updates.when(
            data: (list) => list.isEmpty
                ? Text(
                    l10n.managePageNoUpdatesAvailableDescription,
                    style: textTheme.titleMedium,
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final info in list) _UpdateRow(info: info),
                    ],
                  ),
            // ErrorView's Spacers need bounded height; IntrinsicHeight
            // sizes it to its content inside the unbounded sliver.
            error: (error, _) => IntrinsicHeight(
              child: ErrorView(
                error: error,
                onRetry: () => ref.invalidate(unifiedUpdatesProvider),
              ),
            ),
            loading: () => const Center(
              child: YaruCircularProgressIndicator(),
            ),
          ),
          if (_updateAllError != null) ...[
            const SizedBox(height: kSpacing),
            Text(
              _updateAllError!,
              style: textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One available update: backend badge, name, the version step, and — while
/// its update is in flight — live progress + cancel controls matched by
/// identity out of [activeOperationsProvider]. The UI never learns what a
/// snap or a deb is — the identity stays opaque and is only passed back to
/// the host on update-all.
class _UpdateRow extends ConsumerWidget {
  const _UpdateRow({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final versions = [
      info.fromVersion,
      info.toVersion,
    ].whereType<String>().where((v) => v.isNotEmpty).join(' → ');

    // Same handle-match as UnifiedInstallButton (LLD §8): the update-all
    // loop keeps its serial enqueue + _awaitTerminal; the row self-renders
    // from the provider, so no handle plumbing through the loop.
    final handle = ref
        .watch(activeOperationsProvider)
        .valueOrNull
        ?.where((h) => h.app == info.identity && !h.current.isTerminal)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpacingSmall),
      child: Row(
        children: [
          _BackendBadge(backendId: info.identity.backendId),
          const SizedBox(width: kSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  info.name,
                  style: textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (versions.isNotEmpty)
                  Text(
                    versions,
                    style: textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (handle != null) ...[
            const SizedBox(width: kSpacing),
            // Trailing slot (shared with the future per-row update
            // button): bounded so the in-flight controls have a finite
            // width to lay out their bar in.
            SizedBox(
              width: 240,
              child: OperationInFlightControls(handle: handle),
            ),
          ],
        ],
      ),
    );
  }
}

/// Which backend owns the update. The UI never learns what a snap or
/// a deb is — it only shows the backend's id as an opaque source
/// label. Same pattern as [UnifiedManagePage]'s badge.
class _BackendBadge extends StatelessWidget {
  const _BackendBadge({required this.backendId});

  final String backendId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        backendId,
        style: theme.textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
