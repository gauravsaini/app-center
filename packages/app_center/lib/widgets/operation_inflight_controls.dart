/// Live progress + cancel controls for an in-flight operation.
///
/// Extracted verbatim from `UnifiedInstallButton`'s `_InFlightControls` /
/// `_ProgressBar` (LLD §7), so the updates surface renders the exact same
/// UI the install button does: determinate bar on real byte progress,
/// indeterminate otherwise, always-on cancel affordance bound directly
/// to [OperationHandle.cancel], and an honest "Cancelling…" caption while
/// the backend winds down.
///
/// No `backend_*` import by design: this widget sees only the handle —
/// the contract types come through `store_host`.
library;

import 'package:app_center/l10n.dart';
import 'package:flutter/material.dart';
import 'package:store_host/store_host.dart';
import 'package:yaru/yaru.dart';

/// Live progress + cancel controls for one in-flight operation.
///
/// Subscribes to [OperationHandle.state] and renders:
/// - Downloading with bytesTotal > 0 → determinate [LinearProgressIndicator]
/// - anything else non-terminal → indeterminate [LinearProgressIndicator]
/// - Cancelling → indeterminate bar plus the "Cancelling…" caption
/// - watchdog-fired stall (handle is [StallAware] and `isStalled`, state not
///   Cancelling) → "Stalled" warning caption, live via `stalledChanges`
///
/// The stop button calls [OperationHandle.cancel] directly and is always
/// enabled — every backend has a real cancel mechanism (HLD §3).
class OperationInFlightControls extends StatelessWidget {
  const OperationInFlightControls({required this.handle, super.key});

  /// Non-terminal handle for one app.
  final OperationHandle handle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // StallAware rides on the handle as a side interface (store_contracts);
    // handles that don't implement it never show a stalled caption.
    final stallAware = handle is StallAware ? handle as StallAware : null;
    return StreamBuilder<OperationState>(
      stream: handle.state,
      initialData: handle.current,
      builder: (context, snapshot) {
        final state = snapshot.data ?? handle.current;
        return Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ProgressBar(state: state),
                  if (state is Cancelling)
                    Text(
                      l10n.snapActionCancellingLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else if (stallAware != null)
                    _StalledCaption(stallAware: stallAware),
                ],
              ),
            ),
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

/// Warning caption shown when the engine watchdog has fired on this
/// operation but the backend never acknowledged the cancel (no `Cancelling`
/// event), so the row would otherwise sit frozen on a dead progress bar.
///
/// Live-updates off [StallAware.stalledChanges]; only renders when the flag
/// is set. The `Cancelling` state takes precedence — its own caption is
/// rendered by the parent and this caption never shows alongside it.
class _StalledCaption extends StatelessWidget {
  const _StalledCaption({required this.stallAware});

  final StallAware stallAware;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StreamBuilder<bool>(
      stream: stallAware.stalledChanges,
      initialData: stallAware.isStalled,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        return Text(
          l10n.stalledLabel,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
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
