# Per-row failure display — HLD + LLD

Parent: [operation-state-machine.md](operation-state-machine.md) (authority),
[update-progress-ux.md](update-progress-ux.md),
[stall-watchdog.md](stall-watchdog.md).

Slice: **docs only — no code in this leaf.** The unified Updates rows
(`_UpdateRow` in `packages/app_center/lib/manage/unified_updates_section.dart`)
show per-row progress + cancel while in flight but drop every terminal
outcome — failures surface only as batch-level `_updateAllError` text.
The install/remove path (`UnifiedInstallButton._CompletedOutcome`)
already keeps per-row terminal outcomes locally
(`_completed` + `_lastHandle` via `addPostFrameCallback`, since the host
removes finished handles from `activeOperationsProvider`). This leaf
specifies the Updates-row equivalent following that proven pattern,
plus the piece both surfaces are missing: a `StoreException → l10n`
localizer. None exists today (§1).

## HLD

### 1. Research findings — how a `StoreException` becomes a string today

Three paths, none of them adequate:

1. **`lib/error/error.dart` → `error_l10n.dart`.** `ErrorMessage.fromObject`
   handles **only legacy `SnapdException`**, via regex pattern-maps over the
   exception *message text* (`network-timeout`, `too many requests`,
   `persistent network error`, `cannot refresh "…" has running apps`).
   There is **zero `StoreException` handling** anywhere in `app_center`
   (verified: the only `StoreException` reference in `lib/` is the install
   button's `on StoreException catch`). The state machine's §7 rule —
   "the host renders localized messages + affordances" — is doc-only so
   far; this slice builds the first real implementation of it.
2. **`UnifiedInstallButton._CompletedOutcome`.** `Failed` renders a bare
   `YaruIcons.error` `IconButton` whose tap target *is* the retry.
   `debugDetail` correctly never reaches the user — but neither does any
   reason. The user sees a red icon and must guess why.
3. **`_updateAll` catch.** `failures.add('${info.name}: $e')`.
   `StoreException` overrides no `toString`, so `$e` renders
   `Instance of 'BackendUnavailableException'` — neither localized nor
   useful. Batch-level only; rows render nothing.

Consequence: the new localizer keys on `StoreException.code` — stable for
telemetry + i18n per §7 — and **never on message text**. Keying on text is
exactly the legacy `ErrorMessage` regex approach that §7's taxonomy was
built to replace.

### 2. Existing `app_en.arb` keys (reused, not changed)

- `snapActionCancelLabel` ("Cancel"), `snapActionCancellingLabel`
  ("Cancelling…"), `stalledLabel` ("Stalled") — in-flight, untouched.
- `managePageUpdateAllLabel`, `managePageUpdatesAvailable`,
  `managePageNoUpdatesAvailableDescription` — section chrome, untouched.
- `managePageUpdatesFailed` / `managePageUpdatesFailedBody` — legacy
  snapd consolidated-errors path (`ErrorMessageConsolidated`); batch-level,
  untouched by this slice.
- `snapActionUpdateLabel`, `snapActionUpdatingLabel`,
  `unifiedDetailsUpdateLabel` — action labels, untouched.
- Retry label: **`UbuntuLocalizations.of(context).retryLabel`**
  (ubuntu_localizations, re-exported via yaru — already used by
  `ErrorView`). Reused for per-row retry; **not** duplicated into
  `app_en.arb`.

Per repo rules only `app_en.arb` is edited (Weblate owns the rest).

### 3. Failure signals → row UI

One update = one handle = one state machine (§1 of the authority doc).
These are the signals that can reach a row, and what the row shows for
each. Terminal rendering lives in the row's trailing 240px slot
(LLD §9); `OperationInFlightControls` keeps rendering only non-terminal
states (confirmed no change needed — §10).

| Signal | Row shows | Retry? | Styling |
|---|---|---|---|
| `Failed` with remediation `retry`: `network`, `verification`, `interrupted`, `timeout` (incl. the watchdog's `Failed(TimeoutException(stalledPhase))` when the backend ignores the watchdog cancel past the 30s grace) | error icon + concise localized reason (LLD §8) | **yes** | error color |
| `Failed(DiskSpaceException)` (`freeSpace`) | error icon + disk-full reason | no — no disk-cleanup surface exists; a dead button would be dishonest | error color |
| `Failed(BackendUnavailableException)` (`fixBackend`), incl. enqueue-thrown (backend missing / flag-disabled, host `enqueue` throws before any handle exists) | error icon + backend-unavailable reason | no | error color |
| `Failed(PermissionException)` (`fixBackend`) | error icon + confinement reason | no | error color |
| `Failed(UnknownStoreException)` (`reportBug`) | error icon + generic reason. `rawOutput` never rendered. | no | error color |
| `Failed` with remediation `none`: `AuthException` (any of `auth_denied` / `auth_dismissed` / `auth_expired`), `DependencyException`, `AppNotFoundException`, `ConflictException` | **quiet note**: one-line localized reason, neutral caption styling, no icon alarm | no | neutral |
| `Done(cancelRequested: true)` — user cancelled past the point of no return, the op completed anyway | ok icon + neutral one-line note ("finished before the cancel took effect") | no | neutral |
| `Done` (plain) — update succeeded | ok icon only (row vanishes on the provider refresh the slice triggers — LLD §9) | no | neutral |
| `Cancelled` — incl. the watchdog-cancel → `Cancelled` path | **nothing**: quiet return to the pre-action row. Never error-styled, never a note. | n/a | — |

Styling rule behind the table: **error styling is reserved for states
where a user action can change the outcome** (retry / free space /
report). `remediation == none` means nothing the user can do — a red
icon there is nagging, not information. Auth-denied is the sharpest
case: §7 mandates "nothing but a quiet note", and a dismissed polkit
prompt must never look like a failure.

`debugDetail` and `rawOutput` never reach the UI in any row. Ever.

### 4. Cancel-vs-failure visual rule (normative)

- **User-cancelled = quiet return to pre-action state.** `Cancelled`
  clears the row's local `_completed` (never stored) and the row renders
  exactly as before the update started. No icon, no color, no text.
  (Install-button precedent: `_completed = terminal is Cancelled ? null
  : …`.)
- **Failed = error icon + concise reason + retry (when retryable).**
  The reason is the localized `code` message (LLD §8); the icon is
  `YaruIcons.error` at 16px in `colorScheme.error`.
- These two are never mixed: a backend MUST NOT convert a user cancel
  into a generic failure (authority §2), and the row MUST NOT render a
  `Cancelled` with failure styling even if a backend violates that.

### 5. Retry semantics

- Retry = `await ref.read(storeHostProvider).enqueue(OperationKind.update,
  info.identity)`, mirroring the install button's `_enqueue`
  (which also clears `_completed` first and catches enqueue-thrown
  `StoreException` into a local `Failed`).
- **Dedupe:** the host returns the existing handle when one is
  non-terminal for the `AppIdentity` (host `enqueue`, one-active-op rule,
  authority §8) — a double-tap while in flight cannot double-enqueue.
  The row's own guard (retry affordance replaced by in-flight controls
  the moment the new handle appears in the provider) makes the second
  tap unreachable in practice; the host dedupe is the backstop.
- **After terminal the host drops the handle** (`_watchTerminal` removes
  the key from `_inflight` and re-emits active), so retry always starts a
  fresh operation. No stale-handle reuse.
- Retry clears the row's `_completed` *before* enqueueing, so a slow
  `enqueue` never shows the old failure under the new in-flight bar.

**Edge — per-row retry while the update-all loop is running: DISABLED.**
Rule: the section passes `updateAllRunning` into each row; while true,
per-row retry affordances render disabled (`onPressed: null`).

Justification:

1. **One owner per batch lifecycle.** The loop serializes
   `enqueue` + `_awaitTerminal` per row and owns the batch from first
   enqueue to final `unifiedUpdatesProvider` invalidation. A
   user-triggered retry interleaves a second handle lifecycle for the
   same identity that the loop never awaited; the loop's end-of-batch
   invalidate can then land mid-retry and leave the row showing a stale
   outcome.
2. **The engine serializes anyway.** One mutating operation per backend
   at a time (authority §8) — an enabled retry would sit in `queued`
   behind the loop's own work, i.e. a button that promises immediacy it
   can't deliver.
3. **Cost is bounded.** The loop is serial and each item resolves to
   terminal on its own; the failed row becomes retryable the moment the
   batch ends, and the batch-end `_updateAllError` text already names
   what failed.

The alternative — restructuring the loop into a work-queue that absorbs
retries — is a bigger, separate slice. Not this one.

### 6. `UnifiedInstallButton._CompletedOutcome`: reason line IN

**Recommendation: add the reason line for `Failed`; leave `Done` as
icon-only.**

- The visual language must match across rows: "error icon + concise
  reason + retry" everywhere a `Failed` can appear. The localizer
  (LLD §8) is built anyway; wiring one `Text` into `_CompletedOutcome`
  is the cheapest way to keep install/remove rows and update rows
  speaking the same language.
- `Done` stays icon-only: its meaning is unambiguous, and the install
  button's slot has no room for a caption that adds information.
- `Cancelled` already returns to idle — untouched.
- Layout delta is minimal: the existing error `IconButton` keeps its
  retry tap-target role (existing tests keep tapping it); the reason
  text sits beside it. The update row's slot is wider (240px) so it
  gets an explicit `TextButton` retry instead — same localizer, same
  label, slot-driven difference, documented here so the trim reviewer
  sees the call was deliberate. The two widgets stay separate private
  classes; consistency comes from the shared localizer, not a shared
  widget (their layouts genuinely differ).

### 7. Remediation-aware affordances (normative)

Driven by `StoreException.remediation`, not by exception type:

- `retry` → retry affordance (row: `TextButton` with
  `UbuntuLocalizations.retryLabel`; install button: existing error
  `IconButton` tap target).
- `freeSpace` → reason line only. §7's authority text imagines a "disk
  settings" affordance, but **no disk-cleanup surface exists in
  app_center today** — this slice renders reason-only rather than a
  dead button. Recorded as a deliberate divergence from §7's
  affordance sketch.
- `checkNetwork` → reason line only. (Honest gap: no exception in the
  taxonomy maps to `checkNetwork` today — enum/table drift, §13.)
- `fixBackend` → reason line only (no backend-repair surface exists).
- `reportBug` → reason line only, generic message; `rawOutput` stays
  in logs.
- `none` → quiet neutral note, no affordance, no alarm styling (§3).

## LLD

### 8. `StoreException` localizer — exact contract

New file `packages/app_center/lib/error/operation_error_l10n.dart`
(alongside the legacy `error_l10n.dart`; the legacy file is snapd-only
and stays untouched):

```dart
/// Concise user-facing reason for a failed operation.
///
/// Keyed on [StoreException.code] — stable for telemetry + i18n per
/// operation-state-machine §7. Never keyed on message text (the legacy
/// ErrorMessage regex approach). [StoreException.debugDetail] and
/// [UnknownStoreException.rawOutput] are never surfaced.
String operationFailureReason(StoreException e, AppLocalizations l10n) =>
    switch (e.code) {
      'network' => l10n.operationFailureNetwork,
      'auth_denied' => l10n.operationFailureAuthDenied,
      'auth_dismissed' => l10n.operationFailureAuthDismissed,
      'auth_expired' => l10n.operationFailureAuthExpired,
      'disk_full' => l10n.operationFailureDiskFull,
      'dependency' => l10n.operationFailureDependency,
      'verification' => l10n.operationFailureVerification,
      'backend_unavailable' => l10n.operationFailureBackendUnavailable,
      'confinement' => l10n.operationFailureConfinement,
      'not_found' => l10n.operationFailureNotFound,
      'conflict' => l10n.operationFailureConflict,
      'interrupted' => l10n.operationFailureInterrupted,
      'timeout' => l10n.operationFailureTimeout,
      _ => l10n.operationFailureUnknown,
    };
```

Switch on `code`, not on type: a future subtype reusing an existing
code inherits its message; a new code falls through to the generic
message instead of breaking exhaustiveness. `dep_trace` boundary:
imports `store_contracts` (via `store_host`, same as the section) +
`l10n` only.

New `app_en.arb` keys (English drafts; Weblate owns the rest):

| Key | Draft en value |
|---|---|
| `operationFailureNetwork` | "Couldn't reach the server. Check your connection and try again." |
| `operationFailureAuthDenied` | "Permission was denied, so the update didn't start." |
| `operationFailureAuthDismissed` | "The permission prompt was dismissed, so the update didn't start." |
| `operationFailureAuthExpired` | "The permission expired, so the update didn't start." |
| `operationFailureDiskFull` | "Not enough disk space for this update." |
| `operationFailureDependency` | "The update couldn't be prepared because of unmet dependencies." |
| `operationFailureVerification` | "The download failed verification. Try again." |
| `operationFailureBackendUnavailable` | "The backend for this update isn't available right now." |
| `operationFailureConfinement` | "The app needs permissions this backend can't grant." |
| `operationFailureNotFound` | "This update is no longer available." |
| `operationFailureConflict` | "Another change is in progress for this app." |
| `operationFailureInterrupted` | "The update was interrupted. Try again." |
| `operationFailureTimeout` | "The update stalled and was stopped. Try again." |
| `operationFailureUnknown` | "Something went wrong. Try again." |
| `operationDoneAfterCancelNote` | "The update finished before the cancel took effect." |

Notes: the timeout message deliberately does **not** name the phase —
`stalledPhase` is debug vocabulary ("Applying" means nothing to users).
Auth messages say "didn't start" honestly: an auth failure aborts
before any mutation. `managePageUpdatesFailed` is *not* reused — it is
the legacy snapd-consolidated plural heading, wrong shape for a
per-row line.

### 9. `_UpdateRow` — exact widget contract

`_UpdateRow` becomes a `ConsumerStatefulWidget`, mirroring the install
button's `_completed` / `_lastHandle` pattern (kind is always `update`,
so the record keeps only the terminal state):

```dart
class _UpdateRow extends ConsumerStatefulWidget {
  const _UpdateRow({
    required this.info,
    required this.batchId,
    required this.updateAllRunning,
  });

  final UpdateInfo info;
  final int batchId;            // incremented by the section per _updateAll run
  final bool updateAllRunning;  // per-row retry disabled while true (HLD §5)

  @override
  ConsumerState<_UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends ConsumerState<_UpdateRow> {
  /// Terminal outcome of the last update for this row, kept locally so
  /// the row doesn't flip straight back to idle when the host drops
  /// the finished handle. `Cancelled` is never kept — a cancelled
  /// update returns to idle (HLD §4).
  ({OperationState terminal})? _completed;

  /// Last handle seen for this row, to detect terminal transitions the
  /// host reports by *removing* the handle from the active list.
  OperationHandle? _lastHandle;

  Future<void> _retry() async {
    setState(() => _completed = null);
    try {
      await ref
          .read(storeHostProvider)
          .enqueue(OperationKind.update, widget.info.identity);
    } on StoreException catch (e) {
      // Enqueue-thrown (e.g. BackendUnavailableException): no handle
      // ever existed; record the failure locally like the install button.
      if (mounted) {
        setState(() => _completed = (terminal: Failed(error: e)));
      }
    }
  }

  @override
  void didUpdateWidget(covariant _UpdateRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fresh batch: drop stale per-row outcomes so the new run starts clean.
    if (oldWidget.batchId != widget.batchId) _completed = null;
  }

  @override
  Widget build(BuildContext context) {
    final handle = ref
        .watch(activeOperationsProvider)
        .valueOrNull
        ?.where((h) => h.app == widget.info.identity && !h.current.isTerminal)
        .firstOrNull;

    // Same removal-signal handling as UnifiedInstallButton.
    final prev = _lastHandle;
    _lastHandle = handle;
    if (prev != null && handle == null && prev.current.isTerminal) {
      final terminal = prev.current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _completed = terminal is Cancelled
              ? null
              : (terminal: terminal);
        });
        // A successful update means this row is stale: refresh the list
        // so it disappears. Idempotent — the update-all loop invalidates
        // anyway at batch end.
        if (terminal is Done) ref.invalidate(unifiedUpdatesProvider);
      });
    }
    … // trailing 240px slot: §10 below
  }
}
```

Trailing slot (replaces the current in-flight-only `if (handle !=
null)` block):

```dart
SizedBox(
  width: 240,
  child: handle != null
      ? OperationInFlightControls(handle: handle)   // unchanged
      : _RowTerminalOutcome(
          completed: _completed,
          retryEnabled: !widget.updateAllRunning,
          onRetry: _retry,
        ),
),
```

`_RowTerminalOutcome` (private to the section file):

- `completed == null` → `SizedBox.shrink()` (idle row: name + versions only, as today).
- `Done` → `YaruIcons.ok` 16px; if `result.cancelRequested`, append the
  `operationDoneAfterCancelNote` caption in neutral `bodySmall`.
- `Failed(error)`:
  - `error.remediation == Remediation.none` → quiet note: `Text(reason,
    bodySmall, maxLines: 1, ellipsis)`, no icon, no button (HLD §4/§7).
  - otherwise → `Row(mainAxisSize: min, children: [Icon(YaruIcons.error,
    16, colorScheme.error), SizedBox(8), Expanded(Text(reason, bodySmall,
    maxLines: 1, ellipsis)), if (error.retryable) TextButton(onPressed:
    retryEnabled ? onRetry : null, child: Text(UbuntuLocalizations.of(
    context).retryLabel))])`. (`retryable` is derived:
    `remediation == Remediation.retry` — contracts `errors.dart`.)
- `Cancelled` is unreachable here (never stored) — defensive
  `SizedBox.shrink()`.

Section-level changes in `_updateAll`:

- Increment `_batchId` and pass `batchId: _batchId,
  updateAllRunning: _updatingAll` into each `_UpdateRow`.
- Drive-by (same localizer, one line): the catch becomes
  `failures.add('${info.name}: ${operationFailureReason(e, l10n)}')`
  instead of `'${info.name}: $e'` — otherwise two string paths for the
  same exceptions diverge again. Requires `l10n` at the catch site
  (pass `AppLocalizations` into `_updateAll` from the button's
  `onPressed`, where context exists).

### 10. `OperationInFlightControls` — confirmed no change

It subscribes to `handle.state` and renders only non-terminal states
(determinate/indeterminate bar, "Cancelling…", "Stalled" caption). Rows
switch to `_RowTerminalOutcome` exactly when the handle leaves the
provider, so the shared widget never sees a terminal state. No new
parameters, no new imports.

### 11. Test matrix

`app_center`, flat in `test/` per test conventions
(`tearDown(resetAllServices)`; `pumpApp`; `tester.l10n`):

`operation_error_l10n_test.dart` (new):

- every `code` in the taxonomy maps to a non-empty localized string;
- an unrecognized code (constructed via a test-only `StoreException`
  subtype) falls through to `operationFailureUnknown`;
- `debugDetail` / `rawOutput` text never appears in any output
  (assert `find.textContaining(debugDetail)` finds nothing).

`unified_updates_section_test.dart` (extend; reuse
`test/fake_inflight_handle.dart`'s scriptable `FakeInFlightHandle` and
the existing `activeOperationsProvider` / `storeHostProvider`
overrides):

- `Failed(NetworkException(debugDetail: 'boom'))` → row shows the
  network reason + enabled retry; `find.text('boom')` finds nothing.
- retry tap → `verify(host.enqueue(OperationKind.update, identity))
  .called(1)`; drive the fake to `Downloading` through the provider
  override → retry affordance replaced by in-flight controls; a second
  tap is impossible and `enqueue` stays at 1 call (no double-enqueue).
- retry tap with `enqueue` throwing `BackendUnavailableException` →
  row shows the backend-unavailable reason with NO retry button
  (HLD §3: `fixBackend` remediation → reason only; a retry whose
  backend is gone cannot succeed, so the button stays off).
- `Failed(TimeoutException(debugDetail: '…', stalledPhase: 'Applying'))`
  → stalled reason + retry (watchdog path).
- `Failed(AuthException(…denied…))` → quiet neutral note, no retry
  button, no error-colored icon.
- `Cancelled` terminal → row returns to idle rendering (no error icon,
  no reason text).
- `Done(cancelRequested: true)` → ok icon + neutral note, no
  error styling.
- update-all running (`updateAllRunning: true`) → per-row retry
  `onPressed` is null; batch start (`batchId` change) clears a
  previously shown failure.
- per-row `Done` → `unifiedUpdatesProvider` invalidated (row refreshes
  away).

`unified_install_button_test.dart` (extend):

- `Failed` now renders the localized reason line beside the existing
  error `IconButton`; tapping the icon still retries (existing
  assertions preserved).

`store_host` / `store_contracts`: no changes, no new tests.

### 12. Acceptance criteria (verifier-checkable)

- [ ] This doc is the only file in the slice; no `lib/` or `test/`
  changes.
- [ ] (Follow-up code slice) every `_UpdateRow` terminal signal renders
  per the HLD §3 table; `OperationInFlightControls` is byte-identical.
- [ ] `operationFailureReason` covers all 12 `code` values, switches on
  `code` only, and no `debugDetail`/`rawOutput`/message-text reaches
  the UI in any path.
- [ ] `app_en.arb` gains exactly the 15 keys in LLD §8; `melos gen-l10n`
  regenerates cleanly (CI l10n-freshness gate).
- [ ] `dep_trace.py` reports zero new violations (new file imports
  `store_contracts`/`store_host` + `l10n` only — the section's existing
  sanctioned boundary).
- [ ] All LLD §11 tests green; `melos test` and
  `melos analyze --fatal-infos` clean.

### 13. Honest gaps

- No live-daemon verification possible in the sandbox (no snapd /
  PackageKit / flatpak) — same standing gap as the progress-UX and
  watchdog slices; widget tests use scripted fake handles.
- New arb keys ship English-only until Weblate translates them.
- `Remediation.checkNetwork` is unmapped: no exception in the taxonomy
  carries it (enum/table drift inherited from §7). If a backend ever
  uses it, the localizer renders reason-only per HLD §7.
- The timeout reason intentionally omits `stalledPhase` — debug
  vocabulary, not user vocabulary.
- `Done(cancelRequested: true)` interim display races the provider
  refresh; the row disappears on refresh regardless.
- Auth (polkit) dismissal/denial flows can't be exercised in widget
  tests; the quiet-note path is covered with constructed
  `AuthException`s only.
- Per-row retry stays disabled for the whole update-all batch even if
  the batch is long (e.g. slow deb configure) — accepted tradeoff,
  HLD §5.
- §7's "disk settings" affordance for `freeSpace` has no target surface
  in app_center; this slice deliberately renders reason-only (HLD §7).
