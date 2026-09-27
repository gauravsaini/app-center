/// `store_host` — host-side orchestration.
///
/// The host owns the catalog, the operations, the flags, and the
/// policy. Backends are plugins registered at the composition root
/// (the app's `main.dart`); UI pages import only this package and
/// `store_contracts` — never `backend_*`.
library store_host;

export 'package:store_contracts/store_contracts.dart';
export 'src/check_updates_result.dart';
export 'src/flags.dart';
export 'src/host.dart';
export 'src/identity/community_refresh.dart';
export 'src/identity/community_transport.dart';
// The metadata doc's UI-facing types only: CommunityAppMetadata (the
// details page renders it) and CommunityMetadataRefreshResult (future
// settings affordance). The parse plumbing (CommunityScreenshot,
// CommunityPermissions, CommunityRating, CommunityMetadataStore)
// stays host-internal — same pattern as slice 4 §6.
export 'src/identity/community_metadata.dart'
    show CommunityAppMetadata, CommunityMetadataRefreshResult;
export 'src/identity/identity_resolver.dart';
export 'src/installed_result.dart';
export 'src/platform_detection.dart';
