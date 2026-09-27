/// The unified app details page (strangler-fig slice).
///
/// One page that renders identically for snap, deb, and flatpak apps.
/// All data comes from [StoreHost.getDetails] — never from backend
/// services directly, never `backend_*`.
///
/// ADR-009: the permissions section renders BEFORE any install action.
/// When the host hands the page a [UnifiedApp] with several variants, the
/// format switcher keeps each format's card separate. With
/// `phase3.identity.enabled` and a resolved canonical id the switcher
/// becomes the merged-card format picker (badge + version + size +
/// installed state per format); otherwise it stays the legacy backend
/// switcher, bit for bit.
library;

import 'package:app_center/error/error.dart';
import 'package:app_center/l10n.dart';
import 'package:app_center/layout.dart';
import 'package:app_center/search/search_provider.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:app_center/store/store_operations.dart';
import 'package:app_center/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:store_host/store_host.dart';
import 'package:yaru/yaru.dart';

/// Unified details for one backend app.
///
/// [identity] is the source of truth; [app] (when the caller has the
/// search-time [UnifiedApp]) pre-fills the header and supplies the
/// variant list for the backend switcher.
class UnifiedDetailsPage extends ConsumerStatefulWidget {
  const UnifiedDetailsPage({
    required this.identity,
    this.app,
    super.key,
  });

  final AppIdentity identity;
  final UnifiedApp? app;

  @override
  ConsumerState<UnifiedDetailsPage> createState() => _UnifiedDetailsPageState();
}

class _UnifiedDetailsPageState extends ConsumerState<UnifiedDetailsPage> {
  late AppIdentity _selected = widget.identity;

  List<AppInfo> get _variants => widget.app?.variants ?? const [];

  AppInfo? get _selectedVariant {
    for (final v in _variants) {
      if (v.identity == _selected) return v;
    }
    return _variants.isNotEmpty ? _variants.first : null;
  }

  /// Phase 3 merged card: the identity flag is on AND the host resolved
  /// this app to a canonical id. Only then does the format picker (and
  /// the preference persistence) apply — flag off or unresolved keeps
  /// today's backend switcher bit for bit.
  bool get _merged =>
      ref.watch(identityEnabledProvider) && widget.app?.canonicalId != null;

  /// Variant selection.
  ///
  /// Always updates the local selection (header, switcher, and details
  /// follow the picked format). On a merged card this additionally
  /// persists the per-app source preference so the host reorders
  /// `preferred` on the next search (phase3-slice2.md §5) — the install
  /// button itself is untouched. The preference write is fire-and-forget:
  /// the picker selection updates immediately.
  void _onVariantSelected(AppIdentity id) {
    final canonicalId = widget.app?.canonicalId;
    if (_merged && canonicalId != null) {
      _persistPreferredSource(canonicalId, id.backendId);
    }
    setState(() => _selected = id);
  }

  /// Persists the per-app source preference (phase3-slice2.md §4) and
  /// invalidates the unified search so the host reorders and `preferred`
  /// becomes the pick. Unknown backend ids are stored verbatim and
  /// ignored at ordering time (host contract) — this never throws on
  /// user data.
  Future<void> _persistPreferredSource(
    CanonicalAppId id,
    String backendId,
  ) async {
    await ref.read(storeHostProvider).setPreferredSource(id, backendId);
    if (mounted) ref.invalidate(unifiedSearchProvider);
  }

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(unifiedAppDetailsProvider(_selected));
    final merged = _merged;
    return ResponsiveLayoutBuilder(
      builder: (context) {
        final layout = ResponsiveLayout.of(context);
        return SingleChildScrollView(
          padding:
              const EdgeInsets.symmetric(vertical: kPagePadding) +
              ResponsiveLayout.of(context).padding,
          child: Center(
            child: SizedBox(
              width: layout.totalWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header renders immediately from the search-time
                  // variant; the loaded details fill in the real name
                  // once they arrive.
                  _Header(
                    info: details.valueOrNull?.app ?? _selectedVariant,
                    identity: _selected,
                  ),
                  if (_variants.length > 1) ...[
                    const SizedBox(height: kPagePadding),
                    _VariantSwitcher(
                      variants: _variants,
                      selected: _selected,
                      merged: merged,
                      onSelect: _onVariantSelected,
                    ),
                  ],
                  const SizedBox(height: kPagePadding),
                  details.when(
                    data: (d) => _DetailsBody(details: d),
                    loading: () => const Center(
                      child: YaruCircularProgressIndicator(),
                    ),
                    // ErrorView's Spacers need bounded height; IntrinsicHeight
                    // sizes it to its content inside the unbounded scroll view.
                    error: (error, _) => IntrinsicHeight(
                      child: ErrorView(
                        error: error,
                        onRetry: () => ref.invalidate(
                          unifiedAppDetailsProvider(_selected),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.identity, this.info});

  final AppIdentity identity;
  final AppInfo? info;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = info?.name ?? identity.nativeId;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(
          iconUrl: info?.iconUrl.isEmpty ?? true ? null : info!.iconUrl,
          size: 64,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _BackendBadge(source: info?.source),
                ],
              ),
              if (info != null && info!.summary.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  info!.summary,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                [
                  if (info?.version != null) 'v${info!.version}',
                  if (info?.installedVersion != null)
                    l10n.snapActionInstalledLabel,
                ].join(' • '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Format badge — labels where the app came from, never ranks by it.
class _BackendBadge extends StatelessWidget {
  const _BackendBadge({required this.source});

  final AppSource? source;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (source) {
      AppSource.snap => l10n.unifiedDetailsSnapBadge,
      AppSource.deb => l10n.unifiedDetailsDebBadge,
      AppSource.flatpak => l10n.unifiedDetailsFlatpakBadge,
      AppSource.appImage => 'AppImage',
      AppSource.rpm => 'RPM',
      AppSource.pacman => 'pacman',
      AppSource.unknown || null => '?',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// Backend switcher: one entry per variant, no merging. Only rendered
/// when the host actually grouped several variants.
///
/// [merged] turns it into the Phase 3 format picker: each chip shows the
/// source badge, version, humanized size (omitted when unknown — never
/// fabricated), and an installed check icon. False keeps the legacy
/// badge-only switcher bit for bit.
class _VariantSwitcher extends StatelessWidget {
  const _VariantSwitcher({
    required this.variants,
    required this.selected,
    required this.onSelect,
    this.merged = false,
  });

  final List<AppInfo> variants;
  final AppIdentity selected;
  final ValueChanged<AppIdentity> onSelect;
  final bool merged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.unifiedDetailsOtherFormatsLabel,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final v in variants)
              ChoiceChip(
                label: merged
                    ? _formatChipLabel(context, v)
                    : Text(_badgeLabel(context, v.source)),
                selected: v.identity == selected,
                onSelected: (_) => onSelect(v.identity),
              ),
          ],
        ),
      ],
    );
  }

  /// Merged-card chip content: source badge, version, humanized size or
  /// omitted when null (never fabricated), installed check icon.
  Widget _formatChipLabel(BuildContext context, AppInfo variant) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BackendBadge(source: variant.source),
        const SizedBox(width: 6),
        Text(variant.version ?? '—'),
        if (variant.installSizeBytes != null) ...[
          const SizedBox(width: 6),
          Text(context.formatByteSize(variant.installSizeBytes!)),
        ],
        if (variant.isInstalled) ...[
          const SizedBox(width: 4),
          const Icon(YaruIcons.ok, size: 16),
        ],
      ],
    );
  }

  String _badgeLabel(BuildContext context, AppSource source) {
    final l10n = AppLocalizations.of(context);
    return switch (source) {
      AppSource.snap => l10n.unifiedDetailsSnapBadge,
      AppSource.deb => l10n.unifiedDetailsDebBadge,
      AppSource.flatpak => l10n.unifiedDetailsFlatpakBadge,
      AppSource.appImage => 'AppImage',
      AppSource.rpm => 'RPM',
      AppSource.pacman => 'pacman',
      AppSource.unknown => '?',
    };
  }
}

class _DetailsBody extends StatelessWidget {
  const _DetailsBody({required this.details});

  final AppDetails details;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ADR-009: permissions render BEFORE any install action.
        Text(
          l10n.snapPageConfinementLabel,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _PermissionsList(permissions: details.permissions),
        const SizedBox(height: kPagePadding),
        // Install / remove / update through the host. The button keeps
        // its own ADR-009 permission line + disabled-until-loaded action.
        UnifiedInstallButton(
          app: UnifiedApp(
            groupId: 'details:${details.app.identity}',
            variants: [details.app],
          ),
        ),
        const SizedBox(height: kPagePadding),
        Text(
          l10n.unifiedDetailsDescriptionLabel,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(details.description),
        if (details.screenshots.isNotEmpty) ...[
          const SizedBox(height: kPagePadding),
          Text(
            l10n.unifiedDetailsScreenshotsLabel,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _Screenshots(urls: details.screenshots),
        ],
        if (details.license != null || details.homepage != null) ...[
          const SizedBox(height: kPagePadding),
          if (details.license != null)
            _MetaRow(label: 'License', value: details.license!),
          if (details.homepage != null)
            _MetaRow(label: 'Homepage', value: details.homepage!),
        ],
      ],
    );
  }
}

class _PermissionsList extends StatelessWidget {
  const _PermissionsList({required this.permissions});

  final List<Permission> permissions;

  @override
  Widget build(BuildContext context) {
    if (permissions.isEmpty) {
      return Text(
        '?',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).hintColor,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in permissions)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(YaruIcons.information, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(p.label)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Screenshots extends StatelessWidget {
  const _Screenshots({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            urls[i],
            height: 180,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 120,
              child: Center(child: Icon(YaruIcons.image_missing, size: 32)),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
