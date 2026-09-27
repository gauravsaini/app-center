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
import 'package:app_center/error/operation_error_l10n.dart';
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

  /// Incremented per update-all run; rows drop their stale per-row
  /// outcomes when they see it change (per-row-failure LLD §9).
  int _batchId = 0;

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
  Future<void> _updateAll(
    AppLocalizations l10n,
    List<UpdateInfo> updates,
  ) async {
    if (_updatingAll || updates.isEmpty) return;
    setState(() {
      _updatingAll = true;
      _updateAllError = null;
      _batchId++;
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
      } on StoreException catch (e) {
        // One failed start never aborts the remaining updates.
        // Same localizer as the per-row reasons so the batch text and
        // the rows never diverge (per-row-failure LLD §9).
        failures.add('${info.name}: ${operationFailureReason(e, l10n)}');
      } on Exception catch (e) {
        // Non-StoreException: no code to key the localizer on.
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
                    : () => _updateAll(
                        l10n,
                        updates.valueOrNull ?? const [],
                      ),
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
                      for (final info in list)
                        _UpdateRow(
                          info: info,
                          batchId: _batchId,
                          updateAllRunning: _updatingAll,
                        ),
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
/// identity out of [activeOperationsProvider]. Terminal outcomes render
/// per row in the trailing slot (per-row-failure LLD §9); the UI never
/// learns what a snap or a deb is — the identity stays opaque and is only
/// passed back to the host on update-all.
class _UpdateRow extends ConsumerStatefulWidget {
  const _UpdateRow({
    required this.info,
    required this.batchId,
    required this.updateAllRunning,
  });

  final UpdateInfo info;

  /// Incremented by the section per update-all run; a change clears the
  /// row's stale outcome so the new batch starts clean.
  final int batchId;

  /// Per-row retry renders disabled while the update-all batch runs
  /// (per-row-failure HLD §5).
  final bool updateAllRunning;

  @override
  ConsumerState<_UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends ConsumerState<_UpdateRow> {
  /// Terminal outcome of the last update for this row, kept locally so
  /// the row doesn't flip straight back to idle when the host drops
  /// the finished handle from [activeOperationsProvider]. `Cancelled`
  /// is never kept — a cancelled update returns to idle
  /// (per-row-failure HLD §4).
  ({OperationState terminal})? _completed;

  /// Last handle seen for this row, to detect terminal transitions the
  /// host reports by *removing* the handle from the active list.
  OperationHandle? _lastHandle;

  Future<void> _retry() async {
    // Clear before enqueueing: a slow enqueue must never show the old
    // failure under the new in-flight bar.
    setState(() => _completed = null);
    try {
      await ref
          .read(storeHostProvider)
          .enqueue(OperationKind.update, widget.info.identity);
    } on StoreException catch (e) {
      // Enqueue-thrown (e.g. BackendUnavailableException): no handle
      // ever existed; record the failure locally like the install
      // button.
      if (mounted) {
        setState(() => _completed = (terminal: Failed(error: e)));
      }
    }
  }

  @override
  void didUpdateWidget(covariant _UpdateRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fresh batch: drop stale per-row outcomes so the new run starts
    // clean.
    if (oldWidget.batchId != widget.batchId) _completed = null;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final versions = [
      widget.info.fromVersion,
      widget.info.toVersion,
    ].whereType<String>().where((v) => v.isNotEmpty).join(' → ');

    // Same handle-match as UnifiedInstallButton (LLD §8): the update-all
    // loop keeps its serial enqueue + _awaitTerminal; the row self-renders
    // from the provider, so no handle plumbing through the loop.
    final handle = ref
        .watch(activeOperationsProvider)
        .valueOrNull
        ?.where(
          (h) => h.app == widget.info.identity && !h.current.isTerminal,
        )
        .firstOrNull;

    // The host signals completion by removing the handle: record the
    // terminal outcome (except Cancelled, which returns to idle) so the
    // row doesn't snap back to idle.
    final prev = _lastHandle;
    _lastHandle = handle;
    if (prev != null && handle == null && prev.current.isTerminal) {
      final terminal = prev.current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _completed = terminal is Cancelled ? null : (terminal: terminal);
        });
        // A successful update means this row is stale: refresh the list
        // so it disappears. Idempotent — the update-all loop invalidates
        // anyway at batch end.
        if (terminal is Done) ref.invalidate(unifiedUpdatesProvider);
      });
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpacingSmall),
      child: Row(
        children: [
          _BackendBadge(backendId: widget.info.identity.backendId),
          const SizedBox(width: kSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.info.name,
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
          const SizedBox(width: kSpacing),
          // Trailing slot (shared with the per-row update button):
          // bounded so the in-flight controls have a finite width to
          // lay out their bar in, and the terminal outcomes have room
          // for icon + reason + retry.
          SizedBox(
            width: 240,
            child: handle != null
                ? OperationInFlightControls(handle: handle)
                : _RowTerminalOutcome(
                    completed: _completed,
                    retryEnabled: !widget.updateAllRunning,
                    onRetry: _retry,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Per-row terminal outcome, shown in the row's trailing 240px slot
/// once the host drops the finished handle (per-row-failure LLD §9).
/// `OperationInFlightControls` keeps rendering only non-terminal
/// states — it never sees this widget's inputs.
class _RowTerminalOutcome extends StatelessWidget {
  const _RowTerminalOutcome({
    required this.completed,
    required this.retryEnabled,
    required this.onRetry,
  });

  final ({OperationState terminal})? completed;
  final bool retryEnabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final completed = this.completed;
    // Idle row (or a cancelled update, which returns to idle): nothing.
    if (completed == null) return const SizedBox.shrink();

    final terminal = completed.terminal;
    if (terminal is Done) {
      final children = <Widget>[
        const Icon(YaruIcons.ok, size: 16),
      ];
      if (terminal.result.cancelRequested) {
        // The op completed past the point of no return: say so quietly.
        children.addAll([
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppLocalizations.of(context).operationDoneAfterCancelNote,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]);
      }
      return Row(mainAxisSize: MainAxisSize.min, children: children);
    }
    if (terminal is Failed) {
      final error = terminal.error;
      final reason = operationFailureReason(
        error,
        AppLocalizations.of(context),
      );
      final caption = Theme.of(context).textTheme.bodySmall;
      // remediation == none: nothing the user can do — a quiet note,
      // never error-styled (per-row-failure HLD §4/§7).
      if (error.remediation == Remediation.none) {
        return Text(
          reason,
          style: caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }
      // Actionable failure: error icon + concise reason + retry only
      // for the retry remediation. freeSpace / checkNetwork /
      // fixBackend / reportBug render reason-only — no dead buttons.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            YaruIcons.error,
            size: 16,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              style: caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (error.retryable)
            TextButton(
              onPressed: retryEnabled ? onRetry : null,
              child: Text(UbuntuLocalizations.of(context).retryLabel),
            ),
        ],
      );
    }
    // Cancelled is never stored (see _UpdateRowState); defensive.
    return const SizedBox.shrink();
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
