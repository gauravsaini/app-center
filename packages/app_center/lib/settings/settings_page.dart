import 'package:app_center/l10n.dart';
import 'package:app_center/layout.dart';
import 'package:app_center/settings/settings.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:yaru/yaru.dart';

/// Settings page: currently a single "App identity" section
/// (docs/architecture/phase3-slice4.md).
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static IconData icon(bool selected) =>
      selected ? YaruIcons.settings_filled : YaruIcons.settings;

  static String label(BuildContext context) =>
      AppLocalizations.of(context).settingsPageLabel;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(kPagePadding),
          sliver: SliverToBoxAdapter(
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: const _AppIdentitySection(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AppIdentitySection extends ConsumerWidget {
  const _AppIdentitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return YaruSection(
      headline: Text(l10n.settingsAppIdentityTitle),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.settingsAppIdentityDescription),
          const SizedBox(height: 8),
          YaruSwitchListTile(
            value: ref.watch(identityEnabledProvider),
            onChanged: (value) => setIdentityEnabled(ref, value),
            title: Text(l10n.settingsIdentityToggleTitle),
            subtitle: Text(l10n.settingsIdentityToggleSubtitle),
          ),
          const Divider(),
          Text(
            l10n.settingsCommunityTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(l10n.settingsCommunityDescription),
          const SizedBox(height: 4),
          Text(
            l10n.settingsCommunitySignatureNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          YaruSwitchListTile(
            value: ref.watch(communityEnabledProvider),
            onChanged: (value) => setCommunityEnabled(ref, value),
            title: Text(l10n.settingsCommunityToggleTitle),
            subtitle: Text(l10n.settingsCommunityToggleSubtitle),
          ),
          const SizedBox(height: 8),
          const _MirrorStatus(),
          const SizedBox(height: 8),
          const _RefreshControl(),
        ],
      ),
    );
  }
}

/// "N mirrors configured" + which mirror won the last successful
/// refresh. Count only — this slice has no mirror editing UI
/// (phase3-slice4.md §5).
class _MirrorStatus extends ConsumerWidget {
  const _MirrorStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mirrors = ref.watch(communityMirrorsProvider);
    final lastWon = ref.watch(
      communityRefreshStateProvider.select((s) => s.lastRecord?.mirror),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.settingsCommunityMirrors(mirrors.length)),
        if (lastWon != null)
          Text(
            l10n.settingsCommunityFromMirror(lastWon),
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _RefreshControl extends ConsumerWidget {
  const _RefreshControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(communityRefreshStateProvider);
    final checking = state is CommunityRefreshChecking;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton(
          onPressed: checking
              ? null
              : () =>
                    ref.read(communityRefreshStateProvider.notifier).refresh(),
          child: Text(l10n.settingsCommunityRefreshButton),
        ),
        const SizedBox(height: 8),
        _RefreshStatus(state: state),
      ],
    );
  }
}

class _RefreshStatus extends StatelessWidget {
  const _RefreshStatus({required this.state});

  final CommunityRefreshUiState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return switch (state) {
      CommunityRefreshChecking() => Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(l10n.settingsCommunityChecking),
        ],
      ),
      CommunityRefreshUpToDate(
        :final entryCount,
        :final generatedAt,
        :final mirror,
        :final keyId,
      ) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsCommunityUpToDate,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            Text(l10n.settingsCommunityEntries(entryCount)),
            if (mirror != null) Text(l10n.settingsCommunityFromMirror(mirror)),
            if (generatedAt != null)
              Text(
                l10n.settingsCommunityGeneratedAt(
                  _formatDateTime(context, generatedAt),
                ),
              ),
            // Shown only when the host reports the signing key id
            // (phase3-slice4.md §6). Honest copy: "signature valid",
            // never "verified safe".
            if (keyId != null) Text(l10n.settingsCommunitySignedBy(keyId)),
          ],
        ),
      CommunityRefreshFailed(:final errorsByMirror, :final lastRecord) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsCommunityFailed,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            for (final entry in errorsByMirror.entries)
              SelectableText(
                '${entry.key}: ${entry.value}',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 4),
            // The persisted last-refresh metadata stays visible: a
            // failed attempt doesn't erase when the last success was.
            _LastRefreshLine(lastRecord: lastRecord),
          ],
        ),
      CommunityRefreshSkipped(:final reason) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.settingsCommunitySkipped),
          Text(reason, style: theme.textTheme.bodySmall),
        ],
      ),
      CommunityRefreshIdle(:final lastRecord) => _LastRefreshLine(
        lastRecord: lastRecord,
      ),
    };
  }
}

class _LastRefreshLine extends StatelessWidget {
  const _LastRefreshLine({required this.lastRecord});

  final CommunityRefreshRecord? lastRecord;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final record = lastRecord;
    if (record == null) {
      return Text(
        l10n.settingsCommunityNeverRefreshed,
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settingsCommunityLastRefresh(
            _formatDateTime(context, record.attemptedAt),
          ),
          style: theme.textTheme.bodySmall,
        ),
        if (record.succeededAt != null)
          Text(
            l10n.settingsCommunityLastSuccess(
              _formatDateTime(context, record.succeededAt!),
            ),
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}

String _formatDateTime(BuildContext context, DateTime dateTime) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.yMd(locale).add_Hm().format(dateTime.toLocal());
}
