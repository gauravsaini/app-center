# AppImage backend — transport research

**Status:** research leaf, read-only. No implementation code written.
**Branch:** `feat/backend-appimage` · **Package:** `packages/backend_appimage` (to be created)
**Parent docs:** [hld.md](hld.md), [lld.md](lld.md), [host-wiring.md](host-wiring.md)
**Pattern to follow:** `packages/backend_{snap,deb,flatpak}` — all outside-world
contact goes through an injectable `Transport`; tests script a stub
(see `packages/backend_flatpak/lib/src/transport.dart`).

This note answers, with verified evidence, what the AppImage transport can
and cannot rely on. Every behavioral claim below is either measured on a
real artifact in this sandbox or cited to a live source. The design
decisions it forces are collected in §8.

---

## 1. Metadata: how an AppImage exposes it

### 1.1 File anatomy (measured)

Downloaded `appimagetool-x86_64.AppImage` (8.8 MB, Type 2, from
`https://github.com/AppImage/AppImageKit/releases/download/continuous/`,
inspected read-only in `/tmp`, deleted afterwards). Findings:

```
$ od -A d -t x1 -j 8 -N 4 appimagetool.AppImage
0000008 41 49 02 00            # "AI\x02" — Type 2 magic at offset 8
$ ./appimagetool.AppImage --appimage-offset
193728                          # squashfs payload starts at byte 193728
$ ./appimagetool.AppImage --appimage-updateinformation
gh-releases-zsync|AppImage|AppImageKit|continuous|appimagetool-x86_64.AppImage.zsync
$ ./appimagetool.AppImage --appimage-extract   # 625 ms, NO FUSE involved
$ ls squashfs-root/
AppRun  appimagetool.desktop  appimagetool.png  .DirIcon  usr
```

Payload root carries `AppRun`, the `.desktop` file, a top-level icon, and
`.DirIcon`. The `.desktop` content:

```ini
[Desktop Entry]
Type=Application
Name=appimagetool
Exec=appimagetool
Comment=Tool to generate AppImages from AppDirs
Icon=appimagetool
Categories=Development;
Terminal=true
```

**Notable:** this build has **no `X-AppImage-Version` key.** `appimagetool`
injects `X-AppImage-Version` from the `VERSION` env var at pack time; when
unset (common on `continuous` builds) the key is simply absent. Version
resolution must therefore be a fallback chain, never a single source:

1. `X-AppImage-Version` in the embedded `.desktop` (most trustworthy when
   present — managers like AppImageLauncher/AppMan read this, not the
   filename),
2. filename parse per the spec's recommended scheme
   `ApplicationName-$VERSION-$ARCH.AppImage`,
3. absent (`null`) — do not invent a version.

The `.desktop` file lives at the payload root **or** under
`usr/share/applications/*.desktop` (both seen in the wild). The transport
must check both locations.

Sources: [AppImageSpec draft](https://github.com/AppImage/AppImageSpec/blob/master/draft.md)
(type formats, magic offsets, filename recommendation);
[brainframe AppImage docs](https://github.com/brainframetech/brainframe/blob/HEAD/docs/appimage.md)
(`X-AppImage-Version` injection, "file name proves nothing").

### 1.2 Type 1 vs Type 2 (spec, verified)

Per [AppImageSpec](https://github.com/AppImage/AppImageSpec/blob/master/draft.md):

- **Type 1:** ISO 9660 (+ Rock Ridge) image, magic `0x414901` (`AI\x01`) at
  offset 8. Legacy; effectively extinct in current releases.
- **Type 2:** ELF executable + appended squashfs, magic `0x414902`
  (`AI\x02`) at offset 8. Everything shipped today.

The spec also reserves Type 0 for "not fully standards-compliant"
portable binaries. Transport identification rule: **ELF + `AI\x01`/`AI\x02`
at offset 8** — do NOT trust the `.AppImage` extension (spec: "MUST NOT
rely on any specific file name extension"). Accept both magics; expect ~100%
Type 2 in practice. Runtime flags (`--appimage-extract`, `--appimage-offset`,
`--appimage-updateinformation`) behave the same for both types.

### 1.3 Reading metadata WITHOUT executing the payload

Four candidate mechanisms, ranked:

| # | Mechanism | Deps on stock Ubuntu | Verdict |
|---|-----------|----------------------|---------|
| 1 | The file's own runtime flags: `--appimage-extract` (full), `--appimage-offset`, `--appimage-updateinformation` | **none** — pure userspace squashfs read, no FUSE | **Primary.** Always works. Requires `chmod +x` on the file first (kernel exec). |
| 2 | `unsquashfs -o <offset> -e <paths>` selective extract | `squashfs-tools` — **not installed by default** (absent in this sandbox) | Optimization when present: extract only `*.desktop` + icons, never the whole ~180 MB. Probe at transport init, fall back to (1). |
| 3 | `7z x -so` | `p7zip` — not default | Same role as (2), weaker availability. |
| 4 | FUSE mount (`--appimage-mount`) | FUSE + (often) `libfuse2`, missing on Ubuntu 24.04+ | Rejected: mounting to *read metadata* is the heaviest option and fails on stock 24.04. |

Key facts behind the ranking:

- `--appimage-extract` needs **no FUSE at all** — it is a userspace squashfs
  read. (Verified: extraction succeeded in this sandbox; independently
  documented in [ferestre's packaging notes](https://github.com/icex/ferestre/blob/HEAD/packaging/appimage/README.md).)
- The full runtime flag surface, from the
  [AppImageKit docs](https://fossies.org/dox/AppImageKit-13/):
  `--appimage-extract`, `--appimage-extract-and-run`, `--appimage-mount`
  (inspect without executing payload), `--appimage-offset`,
  `--appimage-version`, `--appimage-updateinformation`, `--appimage-signature`.
- Full extraction cost scales with payload size (8.8 MB → 625 ms here; a
  180 MB Electron AppImage is seconds + ~500 MB temp). This is exactly why
  [appimagectl](https://github.com/0xharryriddle/appimagectl/blob/HEAD/README.md)
  extracts "only the `.desktop` entry and hicolor icons from the payload —
  never the whole ~180 MB".
- `--appimage-extract` always writes `./squashfs-root` relative to CWD:
  the transport must set `workingDirectory` to a fresh private temp dir per
  extraction, and **copy the AppImage there first** — running flags on the
  user's file requires `chmod +x`, which is a side effect on user data.
  `isAvailable()` (<200 ms, no side effects) must never do this.

**Forced:** D1, D2 (§8).

---

## 2. Scan locations: where AppImages live

`appimaged`'s monitored directories (from its
[README](https://github.com/altairwei/appimaged)):

- `$HOME/Downloads` (or localized equivalent)
- `$HOME/.local/bin`, `$HOME/bin`
- **`$HOME/Applications`** ← the conventional permanent home; appimaged docs
  and community guides tell users to move AppImages here
- `/Applications`, `[any mounted partition]/Applications`
- `/opt`, `/usr/local/bin`

Independent corroboration: `appimagectl scan` defaults to
`~/Downloads`, `~/Desktop`, `~/.local/bin`
([README](https://github.com/0xharryriddle/appimagectl/blob/HEAD/README.md)).

### Recommended `listInstalled()` scan order

1. `~/Applications` — our own install target; scan first, cheapest hit rate.
2. `~/.local/bin`, `~/bin`
3. `/opt`, `/usr/local/bin` (may need no root to *read*)
4. `~/Downloads` (transient; include — appimaged treats a download as
   installed)
5. `/Applications`

Identification per file: read 12 bytes, require ELF magic + `AI\x01`/`AI\x02`
at offset 8. Extension is a hint only. Skip non-regular files and anything we
can't read; never follow the scan into mounted-partition `Applications`
dirs in MVP (unbounded I/O).

`isAvailable()`: this backend is file-based with no daemon — availability is
"can we stat the scan roots", which is always true and <200 ms. The honest
answer is `true` unconditionally (a missing *tool* is not a thing here; the
tool is the AppImage itself).

**Forced:** D2 (§8) — two-tier metadata (filename/magic scan fast,
extraction lazy).

---

## 3. Search: is there a trustworthy network catalog?

### appimage.github.io — live, machine-readable, with caveats

- **Live and current:** https://appimage.github.io/ renders "Here are 1606
  apps that you can run on Linux without installation" (fetched 2026-09-27).
- **Machine-readable feed exists:** https://appimage.github.io/feed.json —
  fetched live, ~10k lines, one item per app:
  `name`, `description`, `categories`, `authors`, `license`, `links`
  (`GitHub` repo + `Download` releases page), `icons` (relative paths),
  `screenshots`. Icons resolve against `https://appimage.github.io/`.
- **Caveats (from the [repo README](https://github.com/AppImage/appimage.github.io)):**
  "the data output format is not finalized yet and is subject to change any
  time without prior notice, until we release a stable version of it."
- **Install gap:** links point at GitHub *repos and releases pages*, not
  direct `.AppImage` download URLs. Turning a feed hit into an install means
  resolving the GitHub Releases API per app (asset-name globbing,
  rate limits, auth for high volume) — a whole subsystem, not a lookup.
- Precedent consumers: AppImagePool, NX Software Center, Manjaro's
  software center (listed in the README) — all treat it as a *browse*
  source, not an install API.

### appimagehub.com — dead

https://www.appimagehub.com/ returns a parked-domain placeholder
("Put the headline here"). Do not use.

### Verdict

**MVP search = local-index-only** (installed apps + scanned directories,
name/comment/filename matching). The `search` capability stays advertised —
the corpus is the local index, and the stream contract (cancellable,
no orphaned processes) is trivially satisfiable.

`feed.json` is a legitimate **post-MVP** network search source, gated
behind: format-pinning (hash the shape we parse), a GitHub-release asset
resolver, and icon URL resolution. It must never be an MVP dependency —
offline/air-gapped use is a stated AppImage user story.

**Forced:** D3 (§8).

---

## 4. Install semantics

### 4.1 The install transaction (MVP)

`install(AppIdentity)` for a *local file* the user points at (MVP has no
network install — §3):

1. **Validate:** ELF + `AI\x01`/`AI\x02` at offset 8
   ([appimagectl does exactly this](https://github.com/0xharryriddle/appimagectl/blob/HEAD/README.md)).
   Reject anything else with a typed `StoreException` — never execute an
   unvalidated file.
2. **Copy** to `~/Applications/<Name>-<version>-<arch>.AppImage`
   (create dir if missing), `chmod +x`, then **sha256-verify copy ==
   source**; delete the copy on mismatch.
3. **Extract metadata** (private temp dir, `chmod +x` on the *copy*):
   `.desktop` entry + icons via the §1.3 mechanism.
4. **Write managed `.desktop`** to `~/.local/share/applications/`:
   - File name `appimage-<slug>.desktop` — the prefix prevents shadowing a
     distro package's entry of the same name (XDG precedence would otherwise
     let `firefox.desktop` from an AppImage override the deb's).
     Precedent: [appimagery](https://github.com/viswalahiri/appimagery/blob/HEAD/README.md).
   - `Exec=<absolute path to ~/Applications copy> %U` (rebuild from the
     embedded entry's field codes; never copy its relative `Exec=` verbatim).
   - `Icon=`: icon installed to the hicolor tree (§6), referenced by name;
     fall back to an absolute extracted-icon path if theme install fails.
   - Preserve `Name`, `Comment`, `Categories`, `Keywords`, `MimeType`,
     `StartupNotify`, `StartupWMClass`, `Terminal` from the embedded entry.
   - **Provenance keys** (so remove/verify/uninstall only touch our own
     files — no manifest drift):
     `X-LibreStore-Managed=true`, `X-LibreStore-Path=<abs path>`,
     `X-LibreStore-Sha256=<hex>`.
     Precedent: appimagectl's `X-AppImageCtl-*`, appimagery's `X-Appimagery-*`.
   - Run `desktop-file-validate` when present; roll back on failure.
5. **Refresh caches** (best-effort, ignore failures):
   `update-desktop-database ~/.local/share/applications`,
   `gtk-update-icon-cache ~/.local/share/icons/hicolor`.
6. **Record a manifest** (every file created) under the backend's state dir —
   `remove()` deletes exactly the manifest's files.

### 4.2 What appimaged does that MVP skips

`appimaged` is a **daemon**: inotify-watches its directories, registers
AppImages on appearance (menu entry, icons, MIME types) and unregisters on
deletion, optionally wraps launches in firejail, integrates thumbnails.
([Announcement](https://discourse.appimage.org/t/new-appimaged-optional-daemon-that-registers-appimages-with-the-system/87),
[usage notes](https://github.com/brenobaptista/blog/blob/HEAD/src/posts/integrating-appimages-with-appimaged.md).)

MVP deliberately does **not** run a daemon: one-shot scan in
`listInstalled()`, integrate-on-install, unintegrate-on-remove. No MIME
registration (MVP), no firejail, no file watching. If the user deletes the
`~/Applications` file out-of-band, the next `listInstalled()` simply stops
reporting it; orphaned `.desktop` entries carry our `X-LibreStore-*` keys so
a `recoverInFlight`/repair pass can identify them later.

`remove()` semantics: delete managed `.desktop` + installed icons per
manifest; move the `~/Applications` binary to trash (recoverable), do not
unlink — precedent: appimagectl's "Trash, not delete". Idempotent:
removing a non-installed app → `Done(noop: true)`.

**Forced:** D5 (§8).

---

## 5. Update: mechanism reality and the honest MVP scope

### 5.1 The mechanism exists and is live

- Authors embed an update-information string at pack time, e.g.
  `appimagetool -u "gh-releases-zsync|user|repo|latest|App-*-x86_64.AppImage.zsync"`
  (format verified live in §1.1). The string names a **`.zsync` sidecar**
  uploaded next to the AppImage on GitHub Releases; the updater fetches only
  changed blocks (delta update).
- Readback is free: `--appimage-updateinformation` (verified live);
  check-for-update via `appimageupdatetool --check-for-update <file>`.
- Updater implementations: official `AppImageUpdate`
  (repo moved to `AppImageCommunity/AppImageUpdate`, still publishing
  continuous builds — 2025-10-18 assets observed); the actively maintained
  fork [`pkgforge-dev/AppImageUpdate`](https://github.com/pkgforge-dev/appimageupdate/blob/HEAD/CHANGELOG.md)
  (changelog 2026-03-23, TOML config, GitHub API proxy); `appimg`
  (delta-aware, 2026-09-02 changelog); AM; `appimagectl`.
- Real-world wiring precedent: apps bundle `appimageupdatetool` and launch
  it detached against `$APPIMAGE`
  ([example](https://github.com/gorlix/focus-mode-app-linux/commit/1271afa502be5cf2b2d04607bfcb4f53cc)).

### 5.2 Why MVP excludes it anyway

1. **Coverage is opt-in per app.** Many AppImages embed *no* update
   information at all. appimagectl's documented policy is "honest updates":
   report `not updatable` rather than inventing one. A `checkUpdates()`
   that only works for the subset with `gh-releases-zsync` strings is a
   half-feature.
2. **Version comparison is fuzzy.** `latest`/`continuous` tags are moving
   targets; "newer" has to be derived from release metadata, not the
   embedded string (appimg's changelog documents exactly this pain).
3. **Applying an update needs a zsync engine** (`appimageupdatetool` or a
   reimplementation) — not present on stock Ubuntu, and bundling one is a
   project of its own. Detection without application is worse than nothing:
   it promises what the `update()` handle can't deliver.
4. **No catalog to diff against** (§3 verdict) — unlike flatpak's
   `remote-ls --updates`, there is no central "which versions exist" query.

### Verdict

- **Exclude `BackendCapability.update` from MVP capabilities.**
- **`checkUpdates()` → `[]`** in MVP, documented: no catalog, no bundled
  updater, per-app opt-in coverage. Revisit as one unit (detect + apply)
  when/if we vendor a zsync engine.
- The embedded update-information string is still worth surfacing as an
  informational field on `AppDetails` (e.g. "updates via zsync" vs
  "no update channel") — read-only, no promises.

**Forced:** D4 (§8).

---

## 6. Icons: extraction approach and cost

Icon lookup order, corroborated by the live artifact (§1.1) and two
independent integration guides
([skill](https://github.com/paulrauchbach/linux-setup/blob/HEAD/configs/agents/skills/appimage-integrate/SKILL.md),
[appimagery](https://github.com/viswalahiri/appimagery/blob/HEAD/README.md)):

1. Top-level `<Icon>.png`/`.svg` matching the desktop entry's `Icon=` value
   (measured: `squashfs-root/appimagetool.png`, 128×128).
2. `.DirIcon` target (measured: 128×128 PNG at payload root).
3. `usr/share/icons/hicolor/<size>x<size>/apps/` (measured:
   `usr/share/icons/hicolor/128x128/apps/appimagetool.png`).
4. `usr/share/pixmaps/` (fallback).

Selection rules: prefer the `Icon=`-named file; among candidates prefer
SVG/scalable, else the largest sane PNG; never treat a vendored icon *theme*
as candidates (bundles ship whole themes — picking a 22px status icon for
the launcher is the classic failure).

Install: copy per-size PNGs into
`~/.local/share/icons/hicolor/<size>x<size>/apps/` and reference by **name**
in the `.desktop` `Icon=` field, so the shell picks the right size per
context (taskbar vs app grid). Sizes come from the PNG IHDR header — no
ImageMagick needed. Fallback: absolute `Icon=` path to the extracted file
(skips the icon-cache-refresh dependency).

**Cost:** icons ride the same extraction pass as the `.desktop` file —
no extra process. With selective `unsquashfs` (when available) the pass
touches kilobytes; with full `--appimage-extract` it costs the full payload
read (§1.3). Either way, extraction output is cached keyed by file sha256 —
icons and desktop entry are re-read from cache, never re-extracted.

---

## 7. Permissions

AppImages run **unsandboxed as the invoking user** — there is no permission
manifest to enumerate (contrast snap/flatpak). The honest surface is a
static disclosure in `AppDetails`, not a capability: "runs with your user's
full privileges; no sandbox". MVP does **not** advertise
`BackendCapability.permissions`. (firejail wrapping, which appimaged offers
optionally, is out of scope.)

---

## 8. Design decisions forced by this research

- **D1 — Transport = the AppImage's own runtime flags.** `CliAppImageTransport`
  copies the target file to a private temp dir, `chmod +x` the copy, and
  shells out to `--appimage-extract` / `--appimage-offset` /
  `--appimage-updateinformation` with `workingDirectory` set to the temp dir.
  Zero host dependencies beyond the file itself. If `unsquashfs` is found
  on `PATH` at transport init, use `unsquashfs -o <offset> -e <paths>` for
  selective extraction (desktop + icons only); otherwise full extract.
  Never FUSE-mount for metadata. Never `chmod +x` the user's original.
- **D2 — Two-tier metadata.** `listInstalled()` must stay cheap:
  directory scan + 12-byte magic check + filename heuristics only
  (`Name-$VERSION-$ARCH` parse). Full extraction happens lazily in
  `getDetails()`, cached by file sha256. This also keeps `isAvailable()`
  under its 200 ms / no-side-effects contract (`true` unconditionally —
  the backend is file-based, there is no daemon to be missing).
- **D3 — MVP search is local-index-only.** Corpus: installed + scanned-dir
  apps; match on Name/Comment/filename. `appimage.github.io/feed.json`
  (live, 1606 apps, fetched 2026-09-27) is post-MVP only: its format is
  explicitly unstable per its README, and its links are GitHub release
  *pages*, not download URLs — network install needs a release-asset
  resolver that is out of MVP scope. `appimagehub.com` is dead; ignore it.
- **D4 — MVP capabilities: `{search, details, install, remove}`.**
  `update` excluded (no catalog, no bundled zsync engine, per-app opt-in
  coverage — §5.2); `checkUpdates()` returns `[]` with the reason documented.
  `permissions` excluded (unsandboxed by design — static disclosure in
  details). `ratings` excluded (no AppImage ratings service).
- **D5 — Install/remove = managed file operations with provenance.**
  Copy → `~/Applications`, `chmod +x`, sha256-verified copy; managed
  `appimage-<slug>.desktop` with `X-LibreStore-*` provenance keys +
  install manifest; icons to the hicolor tree; best-effort cache refreshes;
  `desktop-file-validate` when present. `remove()` reverses via manifest;
  binary goes to trash, not unlink. Desktop file naming avoids shadowing
  distro entries.
- **D6 — Identity without a registry.** No central id exists; recommend
  `AppIdentity(backendId: 'appimage', appId: <sha256-of-file>)` for
  installed entries (stable across moves/renames) with a Name-slug fallback
  for display. HLD/LLD to finalize.

## 9. Open questions for the HLD/LLD slice

1. `recoverInFlight()`: file-copy installs are atomic enough that
   in-flight recovery is likely `[]` — confirm against the operation state
   machine doc.
2. Whether `~/Downloads` belongs in the default scan set (appimaged says
   yes; it risks surfacing half-downloaded files — magic check mitigates).
3. Mounted-partition `Applications` dirs: excluded from MVP scan (unbounded
   I/O); revisit with a size/time budget.
4. Exact `AppInfo`/`AppDetails` field mapping (icon bytes vs icon name,
   version-nullability) — LLD.

## 10. Verification log

- 2026-09-27: downloaded `appimagetool-x86_64.AppImage` (8.8 MB), verified
  `AI\x02` magic at offset 8, `--appimage-offset` → 193728,
  `--appimage-updateinformation` → `gh-releases-zsync|AppImage|AppImageKit|
  continuous|appimagetool-x86_64.AppImage.zsync`, `--appimage-extract` →
  625 ms without FUSE; inspected `.desktop` (no `X-AppImage-Version`),
  icon layout (top-level PNG, `.DirIcon`, hicolor tree). Read-only in
  `/tmp`, deleted after. `unsquashfs`/`7z` confirmed absent (stock-Ubuntu
 -like env).
- 2026-09-27: https://appimage.github.io/ live ("1606 apps");
  https://appimage.github.io/feed.json live (~10k lines, item schema
  confirmed); https://www.appimagehub.com/ dead (parked placeholder).
- Format-instability disclaimer quoted verbatim from
  https://github.com/AppImage/appimage.github.io README.
