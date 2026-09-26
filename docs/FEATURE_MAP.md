# Feature Map — Ubuntu App Center (fork)

> For agents and humans: every user-facing feature, what it does, and how a
> user reaches it. Searchable: `grep '^## ' docs/FEATURE_MAP.md`.
> Checker: `python3 scripts/feature_map_check.py` verifies every route in
> `StoreRoutes` has a map entry.

## How to read an entry

- **What** — the feature in one line.
- **User path** — clicks from app launch.
- **Route** — the `StoreRoutes` constant, if any.
- **Code** — where it lives.
- **Data** — which backend/service it talks to.
- **Notes** — status, known issues, migration relevance.

---

## Explore the storefront

- **What:** Curated banners, featured snaps, category shortcuts. The landing page.
- **User path:** Launch app → sidebar → **Explore**.
- **Route:** `/explore`
- **Code:** `lib/explore/explore_page.dart`
- **Data:** snapd (featured/category snaps), ratings for badges.
- **Notes:** Snap-first by construction — the bias ADR-009 exists to kill.

## Browse a category

- **What:** Grid of snaps in one category (Featured, Productivity, Development, Games…).
- **User path:** Sidebar → category name (e.g. **Productivity**).
- **Route:** `/search?category=<name>` (reuses the search page in category mode)
- **Code:** `lib/search/search_page.dart`, `lib/snapd/snap_category_enum.dart`
- **Data:** snapd section/category queries.

## Search for an app

- **What:** Free-text search across snaps (deb search limited).
- **User path:** Top bar → magnifier icon → type query → results.
- **Route:** `/search?query=<text>`
- **Code:** `lib/search/search_field.dart`, `lib/search/search_page.dart`, `lib/search/search_provider.dart`, `lib/snapd/snap_search.dart`
- **Data:** snapd `/v2/find`; deb via PackageKit search.
- **Notes:** Search error handling was a user PR — still fragile. Future: unified cross-format search (ADR-007/009).
- **Strangler slice:** when `backend.snap.enabled` (default on) and no category filter is active, plain text search sources snap results from `StoreHost.search()` instead of snapd directly (`unifiedSnapSearchProvider`, `AppCardGrid.fromUnifiedApps`); category browsing and flag-off keep the legacy path. Composition root: `lib/store/store_host_wiring.dart` (the only UI file importing `backend_*`). Tapping a unified card reuses the legacy snap details/install flow.

## App details — snap

- **What:** The app page: icon, description, screenshots, ratings, install/update/remove/open buttons, channel switcher.
- **User path:** Any listing → click an app card.
- **Route:** `/snap?snap=<name>`
- **Code:** `lib/snapd/snap_page.dart`, `lib/snapd/snap_model.dart`, `lib/widgets/app_card.dart`, `lib/widgets/app_info_bar.dart`
- **Data:** snapd (SnapModel), ratings.ubuntu.com (degrading per ADR-005).
- **Notes:** Deep-linkable via `snap://<name>` URLs (see `lib/store/store_providers.dart`).

## Install / update / remove a snap

- **What:** The core operation UX: progress, cancel, error states.
- **User path:** App page → **Install** / **Update** / **Remove** button.
- **Route:** (action on `/snap?snap=<name>`)
- **Code:** `lib/snapd/snap_model.dart`, `lib/snapd/snap_action.dart`, `lib/manage/currently_installing_model.dart`
- **Data:** snapd changes API (`/v2/snaps`, `/v2/changes`).
- **Notes:** Being reinvented as `OperationHandle` (ADR-008). Channel switch via `snap_channel_switch_dialog.dart`.

## App details — deb

- **What:** App page for native deb packages.
- **User path:** Search/listing → click a deb-backed app.
- **Route:** `/deb?deb=<id>`
- **Code:** `lib/deb/deb_page.dart`, `lib/deb/deb_model.dart`, `lib/deb/deb_providers.dart`
- **Data:** PackageKit / apt metadata, AppStream.

## Install a local .deb file

- **What:** Double-clicking a `.deb` in the file manager opens the store on an install page.
- **User path:** Files → double-click `foo.deb` → store opens → **Install**.
- **Route:** `/local-deb?local-deb=<path>`
- **Code:** `lib/deb/local_deb_page.dart`, `lib/deb/local_deb_model.dart`
- **Data:** PackageKit session installer (`packagekit-session-installer/`).
- **Notes:** Known issue: `.deb` files not opening from file manager (user-reported).

## Games hub

- **What:** Games category page with featured games and external tools.
- **User path:** Sidebar → **Games**.
- **Route:** (sidebar page, no deep route)
- **Code:** `lib/games/games_page.dart`, `lib/games/games_page_featured.dart`, `lib/games/games_page_external_tools.dart`
- **Data:** snapd games category.

## External tools (games)

- **What:** Third-party gaming tools page (e.g. launchers/utilities).
- **User path:** Games page → external tools section.
- **Route:** `/externalTools`
- **Code:** `lib/games/games_page_external_tools.dart`, `lib/store/store_navigator.dart`

## Manage — installed apps & updates

- **What:** List of installed snaps/debs, available updates, update-all, per-app actions, currently-running operations.
- **User path:** Sidebar → **Manage**.
- **Route:** `/manage`
- **Code:** `lib/manage/manage_page.dart`, `lib/manage/manage_app_tile.dart`, `lib/manage/manage_app_actions.dart`, `lib/manage/manage_app_data.dart`, `lib/manage/snap_updates_model.dart`, `lib/manage/local_deb_updates_model.dart`
- **Data:** snapd + PackageKit.
- **Notes:** Sidebar shows an updates-count badge. Known issues (user-reported): deb ops can't be cancelled; snap install/remove/update can't be cancelled; manage-page CPU usage. All in scope for ADR-008.

## Update all apps

- **What:** One button to refresh every updatable snap/deb.
- **User path:** Manage page → **Update all**.
- **Code:** `lib/manage/manage_page.dart`, updates models above.
- **Data:** snapd refresh + PackageKit update.

## Cancel a running operation

- **What:** Stop an in-flight install/update/remove.
- **User path:** Manage page or app page → **Cancel** on the progress row.
- **Code:** `lib/snapd/snap_model.dart` (`cancel()`), `lib/manage/currently_installing_model.dart`
- **Data:** snapd abort.
- **Notes:** Snap cancel exists; **deb cancel does not** (known issue). ADR-008 makes cancel universal and ≤2s.

## Install missing media codecs (GStreamer)

- **What:** When a media app needs codecs, the store offers to install them.
- **User path:** Triggered from a media app → store opens codec page → **Install**.
- **Route:** `/gstreamer?resources=<name|id…>`
- **Code:** `lib/gstreamer/gstreamer_page.dart` (via `lib/gstreamer/gstreamer.dart`)
- **Data:** PackageKit codec install.

## About

- **What:** App version, links, legal.
- **User path:** Sidebar → **About**.
- **Route:** (sidebar page)
- **Code:** `lib/about/about_page.dart`

---

## Deliberately absent (per ADRs)

- **Ratings UI** — degraded in Phase 0 (ADR-005). Entries above that mention ratings will lose those widgets.
- **Flatpak apps** — backend exists (`packages/backend_flatpak`, CLI wrapper, passes contract exam); UI/host wiring behind `backend.flatpak.enabled` pending (ADR-006).
- **One-card unified apps** — not yet; today snaps and debs are separate cards (ADR-007 is the future).
