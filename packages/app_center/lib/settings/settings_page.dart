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
          // Phase 3 slice 6: community metadata (descriptions,
          // screenshots, permissions, ratings) — a subsection of the
          // App identity section, not a new section (phase3-slice6.md
          // §1). Same shape as the community-identity block above:
          // toggle, mirror status, manual refresh control.
          const Divider(),
          Text(
            l10n.settingsMetadataTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(l10n.settingsMetadataDescription),
          const SizedBox(height: 4),
          Text(
            l10n.settingsMetadataSignatureNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          YaruSwitchListTile(
            value: ref.watch(metadataEnabledProvider),
            onChanged: (value) => setMetadataEnabled(ref, value),
            title: Text(l10n.settingsMetadataToggleTitle),
            subtitle: Text(l10n.settingsMetadataToggleSubtitle),
          ),
          const SizedBox(height: 8),
          const _MetadataMirrorStatus(),
          const SizedBox(height: 8),
          const _MetadataRefreshControl(),
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
            _LastRefreshLine(
              attemptedAt: lastRecord?.attemptedAt,
              succeededAt: lastRecord?.succeededAt,
            ),
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
        attemptedAt: lastRecord?.attemptedAt,
        succeededAt: lastRecord?.succeededAt,
      ),
    };
  }
}

/// "N metadata mirrors configured" + which mirror won the last
/// successful metadata refresh. Count only — no mirror editing UI
/// (phase3-slice6.md §3).
class _MetadataMirrorStatus extends ConsumerWidget {
  const _MetadataMirrorStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mirrors = ref.watch(metadataMirrorsProvider);
    final lastWon = ref.watch(
      communityMetadataRefreshStateProvider.select((s) => s.lastRecord?.mirror),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.settingsMetadataMirrors(mirrors.length)),
        if (lastWon != null)
          Text(
            l10n.settingsCommunityFromMirror(lastWon),
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _MetadataRefreshControl extends ConsumerWidget {
  const _MetadataRefreshControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(communityMetadataRefreshStateProvider);
    final checking = state is CommunityMetadataRefreshChecking;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton(
          onPressed: checking
              ? null
              : () => ref
                    .read(communityMetadataRefreshStateProvider.notifier)
                    .refresh(),
          child: Text(l10n.settingsMetadataRefreshButton),
        ),
        const SizedBox(height: 8),
        _MetadataRefreshStatus(state: state),
      ],
    );
  }
}

class _MetadataRefreshStatus extends StatelessWidget {
  const _MetadataRefreshStatus({required this.state});

  final CommunityMetadataRefreshUiState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return switch (state) {
      CommunityMetadataRefreshChecking() => Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(l10n.settingsMetadataChecking),
        ],
      ),
      CommunityMetadataRefreshUpToDate(
        :final entryCount,
        :final generatedAt,
        :final mirror,
        :final keyId,
      ) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsMetadataUpToDate,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            Text(l10n.settingsMetadataEntries(entryCount)),
            if (mirror != null) Text(l10n.settingsCommunityFromMirror(mirror)),
            if (generatedAt != null)
              Text(
                l10n.settingsMetadataGeneratedAt(
                  _formatDateTime(context, generatedAt),
                ),
              ),
            // Shown only when the host reports the signing key id.
            // Honest copy: "signature valid", never "verified safe".
            if (keyId != null) Text(l10n.settingsCommunitySignedBy(keyId)),
          ],
        ),
      CommunityMetadataRefreshFailed(
        :final errorsByMirror,
        :final lastRecord,
      ) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsMetadataFailed,
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
            _LastRefreshLine(
              attemptedAt: lastRecord?.attemptedAt,
              succeededAt: lastRecord?.succeededAt,
            ),
          ],
        ),
      CommunityMetadataRefreshSkipped(:final reason) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.settingsMetadataSkipped),
          Text(reason, style: theme.textTheme.bodySmall),
        ],
      ),
      CommunityMetadataRefreshIdle(:final lastRecord) => _LastRefreshLine(
        attemptedAt: lastRecord?.attemptedAt,
        succeededAt: lastRecord?.succeededAt,
      ),
    };
  }
}

class _LastRefreshLine extends StatelessWidget {
  /// Shared by the identity-index and metadata refresh statuses: both
  /// record types carry the same two timestamps, and the line renders
  /// from the values, not the record type.
  const _LastRefreshLine({this.attemptedAt, this.succeededAt});

  final DateTime? attemptedAt;
  final DateTime? succeededAt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final attemptedAt = this.attemptedAt;
    if (attemptedAt == null) {
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
            _formatDateTime(context, attemptedAt),
          ),
          style: theme.textTheme.bodySmall,
        ),
        if (succeededAt != null)
          Text(
            l10n.settingsCommunityLastSuccess(
              _formatDateTime(context, succeededAt!),
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
