# dep_trace report — UI/backend coupling map

Scanned 178 Dart files under packages/.

## Layer census
- ui: 50 files
- backend: 29 files
- ratings: 33 files
- system: 13 files
- host: 10 files
- other: 43 files

## VIOLATIONS: UI -> backend imports (44)
Each line is one cut the strangler-fig migration must make.
- `packages/app_center/lib/apps/app_title_bar.dart` imports `package:app_center/deb/deb_model.dart`
- `packages/app_center/lib/apps/app_title_bar.dart` imports `package:app_center/deb/local_deb_model.dart`
- `packages/app_center/lib/apps/app_title_bar.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/apps/apps_utils.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/error/error_l10n.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/explore/explore_page.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/games/games_page.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/games/games_page_external_tools.dart` imports `package:app_center/snapd/snap_category_enum.dart`
- `packages/app_center/lib/games/games_page_featured.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/games/games_page_featured.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/app_providers.dart` imports `package:app_center/packagekit/packagekit.dart`
- `packages/app_center/lib/manage/local_deb_providers.dart` imports `package:app_center/packagekit/packagekit.dart`
- `packages/app_center/lib/manage/local_deb_providers.dart` imports `package:packagekit/packagekit.dart`
- `packages/app_center/lib/manage/local_deb_updates_model.dart` imports `package:app_center/packagekit/packagekit.dart`
- `packages/app_center/lib/manage/local_snap_providers.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/manage/local_snap_providers.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_actions.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_actions.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_data.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_data.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_tile.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_page.dart` imports `package:app_center/snapd/currently_installing_model.dart`
- `packages/app_center/lib/manage/snap_updates_model.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/manage/snap_updates_model.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/search/search_field.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/search/search_field.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/search/search_page.dart` imports `package:app_center/snapd/multisnap_model.dart`
- `packages/app_center/lib/search/search_page.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/search/search_provider.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/search/search_provider.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/app_card.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/widgets/app_card.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/app_info_bar.dart` imports `package:app_center/deb/deb_model.dart`
- `packages/app_center/lib/widgets/app_info_bar.dart` imports `package:app_center/deb/local_deb_model.dart`
- `packages/app_center/lib/widgets/app_info_bar.dart` imports `package:app_center/snapd/snap_data.dart`
- `packages/app_center/lib/widgets/app_title.dart` imports `package:app_center/deb/local_deb_model.dart`
- `packages/app_center/lib/widgets/app_title.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/widgets/app_title.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/banner.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/widgets/banner.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/category_snap_list.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/widgets/dialogs.dart` imports `package:app_center/snapd/snapd.dart`
- `packages/app_center/lib/widgets/dialogs.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/snap_grid.dart` imports `package:snapd/snapd.dart`

## REVERSE: backend/system -> UI imports (6)
- `packages/app_center/lib/deb/deb_page.dart` imports `package:app_center/apps/app_page.dart`
- `packages/app_center/lib/deb/deb_page.dart` imports `package:app_center/apps/app_title_bar.dart`
- `packages/app_center/lib/deb/local_deb_page.dart` imports `package:app_center/apps/app_page.dart`
- `packages/app_center/lib/deb/local_deb_page.dart` imports `package:app_center/apps/app_title_bar.dart`
- `packages/app_center/lib/snapd/snap_page.dart` imports `package:app_center/apps/app_page.dart`
- `packages/app_center/lib/snapd/snap_page.dart` imports `package:app_center/apps/app_title_bar.dart`

## Ratings touchpoints (22)
ADR-005: ratings degrade in Phase 0 — these imports go away or become graceful empty states.
- `packages/app_center/lib/main.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/lib/main.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/lib/snapd/cache_file.dart` imports `package:app_center/ratings/ratings_data.dart`
- `packages/app_center/lib/snapd/snap_page.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/lib/snapd/snap_page.dart` imports `package:app_center/ratings/ratings_data.dart`
- `packages/app_center/lib/widgets/app_card.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/lib/widgets/app_info_bar.dart` imports `package:app_center/ratings/ratings_l10n.dart`
- `packages/app_center/lib/widgets/app_info_bar.dart` imports `package:app_center/ratings/ratings_model.dart`
- `packages/app_center/lib/widgets/app_info_bar.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/lib/widgets/category_snap_list.dart` imports `package:app_center/ratings/rated_category_model.dart`
- `packages/app_center/test/app_card_test.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/test/games_page_test.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/test/ratings_model_test.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/test/ratings_model_test.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/test/ratings_service_test.dart` imports `package:app_center/ratings/ratings_service.dart`
- `packages/app_center/test/ratings_service_test.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/test/search_page_test.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/test/snap_page_test.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/test/snap_page_test.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`
- `packages/app_center/test/store_app_test.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/test/test_utils.dart` imports `package:app_center/ratings/ratings.dart`
- `packages/app_center/test/test_utils.dart` imports `package:app_center_ratings_client/app_center_ratings_client.dart`

## Direct package:snapd importers (45)
- `packages/app_center/lib/apps/apps_utils.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/error/error_l10n.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/games/games_page_featured.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/local_snap_providers.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_actions.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_data.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/manage_app_tile.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/manage/snap_updates_model.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/ratings/rated_category_model.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/search/search_field.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/search/search_provider.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/cache_file.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/multisnap_model.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_category_enum.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_channel_switch_dialog.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_data.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_l10n.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_launcher.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_model.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_page.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_search.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snap_sort.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snapd_cache.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snapd_service.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snapd_watcher.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/snapd/snapx.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/store/store_app.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/app_card.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/app_title.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/banner.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/dialogs.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/lib/widgets/snap_grid.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/error_l10n_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/games_page_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/manage_models_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/manage_page_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/multisnap_model_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/snap_launcher_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/snap_model_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/snap_page_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/snap_updates_model_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/snapd_cache_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/snapd_watcher_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/store_app_test.dart` imports `package:snapd/snapd.dart`
- `packages/app_center/test/test_utils.dart` imports `package:snapd/snapd.dart`

## Proposed migration map (starting point, human to refine)
- `lib/snapd/` (non-UI files) -> `backend_snap`
- `lib/deb/`, `lib/packagekit/` -> `backend_deb`
- `lib/ratings/`, `packages/app_center_ratings_client` -> degraded per ADR-005 (shim or removal)
- `lib/appstream/` -> `store_host` metadata pipeline
- `lib/store/`, `lib/src/`, `lib/providers/` -> `store_host` or UI shell (triage per file)
- UI dirs (`manage/`, `search/`, `explore/`, `apps/`, `games/`, `widgets/`) -> `app_center` UI, via `store_contracts` only
- New: `backend_flatpak` (ADR-006, CLI wrapper, behind flag)
