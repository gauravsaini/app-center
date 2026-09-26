/// Install/remove button for unified-store result cards.
///
/// Drives [StoreHost.enqueue] — never backend services directly. Shows
/// live progress from the handle's state stream, supports cancel, and
/// surfaces pre-install permissions (ADR-009) in the permission line
/// above the action: the action stays disabled until permissions load.
///
/// No `backend_*` import by design: this file sees only the host, the
/// contracts, and the wiring providers.
library;

import 'package:app_center/l10n.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';
import 'package:yaru/yaru.dart';

/// Install/remove through the unified store, for one [UnifiedApp].
class UnifiedInstallButton extends ConsumerStatefulWidget {
  const UnifiedInstallButton({required this.app, super.key});

  final UnifiedApp app;

  @override
  ConsumerState<UnifiedInstallButton> createState() =>
      _UnifiedInstallButtonState();
}

class _UnifiedInstallButtonState extends ConsumerState<UnifiedInstallButton> {
  /// Terminal outcome of the last operation for this app, kept locally so
  /// the button doesn't flip straight back to Install when the host drops
  /// the finished handle from [activeOperationsProvider]. `Cancelled`
  /// is never kept — a cancelled action returns to idle.
  ({OperationKind kind, OperationState terminal})? _completed;

  /// Last handle seen for this app, to detect terminal transitions the
  /// host reports by *removing* the handle from the active list.
  OperationHandle? _lastHandle;

  AppIdentity get _identity => widget.app.preferred.identity;

  bool get _installed => widget.app.preferred.installedVersion != null;

  OperationKind get _actionKind =>
      _installed ? OperationKind.remove : OperationKind.install;

  Future<void> _enqueue() async {
    setState(() => _completed = null);
    try {
      await ref.read(storeHostProvider).enqueue(_actionKind, _identity);
    } on StoreException catch (e) {
      // Typed error: the backend logged the detail; the button surfaces
      // a retry affordance. debugDetail never reaches users raw.
      if (mounted) {
        setState(
          () => _completed = (kind: _actionKind, terminal: Failed(error: e)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ops = ref.watch(activeOperationsProvider).valueOrNull;
    final handle = ops
        ?.where((h) => h.app == _identity && !h.current.isTerminal)
        .firstOrNull;

    // The host signals completion by removing the handle: record the
    // terminal outcome (except Cancelled, which returns to idle) so the
    // UI doesn't snap back to Install.
    final prev = _lastHandle;
    _lastHandle = handle;
    if (prev != null && handle == null && prev.current.isTerminal) {
      final terminal = prev.current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _completed = terminal is Cancelled
              ? null
              : (kind: prev.kind, terminal: terminal);
        });
      });
    }

    if (handle != null) {
      return _InFlightControls(handle: handle);
    }

    final completed = _completed;
    if (completed != null) {
      return _CompletedOutcome(
        completed: completed,
        onRetry: _enqueue,
      );
    }

    final details = ref.watch(unifiedAppDetailsProvider(_identity));
    final permissionsReady = details.hasValue;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PermissionLine(
          details: details,
          onRetry: () => ref.invalidate(unifiedAppDetailsProvider(_identity)),
        ),
        const SizedBox(height: 4),
        _ActionButton(
          kind: _actionKind,
          enabled: permissionsReady,
          onPressed: _enqueue,
        ),
      ],
    );
  }
}

/// ADR-009: permissions are visible BEFORE the install action is enabled.
class _PermissionLine extends StatelessWidget {
  const _PermissionLine({required this.details, required this.onRetry});

  final AsyncValue<AppDetails> details;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final caption = Theme.of(context).textTheme.bodySmall;
    return details.when(
      data: (d) {
        final labels = d.permissions.map((p) => p.label).toList();
        if (labels.isEmpty) return const SizedBox.shrink();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(YaruIcons.information, size: 14),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                labels.join(' • '),
                style: caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox(
        height: 14,
        width: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, _) => Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          icon: const Icon(YaruIcons.refresh, size: 14),
          onPressed: onRetry,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.kind,
    required this.enabled,
    required this.onPressed,
  });

  final OperationKind kind;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return OutlinedButton(
      onPressed: enabled ? onPressed : null,
      child: Text(
        kind == OperationKind.install
            ? l10n.snapActionInstallLabel
            : l10n.snapActionRemoveLabel,
      ),
    );
  }
}

class _InFlightControls extends StatelessWidget {
  const _InFlightControls({required this.handle});

  final OperationHandle handle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StreamBuilder<OperationState>(
      stream: handle.state,
      initialData: handle.current,
      builder: (context, snapshot) {
        final state = snapshot.data ?? handle.current;
        return Row(
          children: [
            Expanded(child: _ProgressBar(state: state)),
            IconButton(
              icon: const Icon(YaruIcons.stop),
              tooltip: l10n.snapActionCancelLabel,
              onPressed: handle.cancel,
            ),
          ],
        );
      },
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.state});

  final OperationState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    // Real byte progress when the backend reports it; indeterminate
    // otherwise — never a fabricated percentage.
    if (s is Downloading && s.bytesTotal != null && s.bytesTotal! > 0) {
      return LinearProgressIndicator(
        value: (s.bytesDone / s.bytesTotal!).clamp(0.0, 1.0),
      );
    }
    return const LinearProgressIndicator();
  }
}

class _CompletedOutcome extends StatelessWidget {
  const _CompletedOutcome({required this.completed, required this.onRetry});

  final ({OperationKind kind, OperationState terminal}) completed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final terminal = completed.terminal;
    if (terminal is Done) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Icon(YaruIcons.ok, size: 16),
      );
    }
    if (terminal is Failed) {
      return Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          icon: const Icon(YaruIcons.error, size: 16),
          onPressed: onRetry,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
