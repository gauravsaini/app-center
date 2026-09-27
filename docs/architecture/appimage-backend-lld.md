# LLD: AppImage backend

Companion to `appimage-backend-hld.md`. Concrete types, algorithms,
and error mapping for `packages/backend_appimage`.

## 1. File layout

```
packages/backend_appimage/
  pubspec.yaml                  # name: backend_appimage, 0.1.0
                                # deps: store_contracts (path), crypto ^3.0.0
                                # dev_deps: test ^1.25.0
  lib/backend_appimage.dart     # barrel: exports backend.dart, identity.dart
  lib/testing.dart              # StubAppimageTransport (NOT in barrel)
  lib/src/transport.dart        # AppImageTransport (abstract) +
                                #   RealAppImageTransport +
                                #   AppImageCommandException, DirEntry
  lib/src/identity.dart         # sha256 helpers, IndexedApp, index cache key
  lib/src/metadata.dart         # parseDesktopFile, parseFilename,
                                #   versionFallback, renderDesktopFile
  lib/src/handle.dart           # AppimageOperationHandle
  lib/src/backend.dart          # BackendAppimage
  test/exam_test.dart           # contract exam + unit tests
```

## 2. Transport API (exact)

```dart
class DirEntry {
  const DirEntry({required this.name, required this.path,
    required this.isFile, required this.size, required this.mtimeMs});
}

class AppImageCommandException implements Exception {
  const AppImageCommandException(this.args, this.exitCode, this.stderr);
  final List<String> args; final int exitCode; final String stderr;
}

abstract class AppImageTransport {
  Future<List<DirEntry>> listDir(String path);          // missing → []
  Future<List<int>> readHead(String path, int n);       // first n bytes
  Future<String> sha256Of(String path);                 // hex, streaming
  Future<String?> extractDesktop(String appImagePath, String outDir);
      // → path of extracted .desktop, or null when unavailable.
      // Real impl: unsquashfs single-file when present, else
      // copy→chmod(copy)→`<copy> --appimage-extract` in outDir.
  Future<String?> extractIcon(String appImagePath, String outDir,
      {required String iconName});
  Future<void> copyFile(String from, String to);
  Future<void> writeTextFile(String path, String content);
  Future<void> deleteFile(String path);                 // missing → ok
  Future<void> chmodX(String path);
  Future<List<String>> runProcess(List<String> args, {String? workingDir});
}
```

All methods throw `AppImageCommandException` on failure; the backend
maps to `StoreException` subtypes (§7). `listDir`/`deleteFile` treat
"missing" as success (normal conditions, ADR-010).

## 3. Scan algorithm (`listInstalled`)

```
const scanDirs = [
  '$HOME/Applications', '$HOME/.local/bin', '$HOME/bin',
  '$HOME/Downloads', '/opt', '/usr/local/bin', '/Applications',
];
for (dir in scanDirs) {
  if (cancelled) break;
  for (entry in await transport.listDir(dir)) {       // non-recursive
    if (!entry.isFile) continue;
    final n = entry.name.toLowerCase();
    if (!(n.endsWith('.appimage') || entry.isExecutable)) continue;
    final head = await transport.readHead(entry.path, 16);
    if (!_isAppImage(head)) continue;                  // ELF + AI\x01|AI\x02 @ 8
    final sha = await _cachedSha(entry);                // (path,size,mtime) key
    index[sha] = IndexedApp(path: entry.path, size: entry.size,
        mtimeMs: entry.mtimeMs, meta: parseFilename(entry.name));
  }
}
```

`_isAppImage(head)`: `head[0..3] == 0x7F,'E','L','F'` and
`head[8..10] == 'A','I',(0x01|0x02)`. Accept both magics (≈100% type 2
in the wild per research).

Prefilter-then-verify: extension/executable-bit prefilter keeps the
`~/Downloads` scan cheap; magic bytes are the decision (never the
extension alone).

## 4. Identity

```dart
class IndexedApp {
  final String path; final int size; final int mtimeMs;
  final String name; final String? version;   // filename-derived, may be null
}
```

- `nativeId` = lowercase hex sha256 of file content (`package:crypto`,
  streamed via `transport.sha256Of`).
- Cache: `Map<String _cacheKey, String _sha>` where
  `_cacheKey = '$path|$size|$mtimeMs'`. Re-hash only on change.
- `AppInfo`:
  ```dart
  AppInfo(
    identity: AppIdentity(backendId: 'appimage', nativeId: sha),
    name: meta.name, summary: meta.comment ?? '',
    iconUrl: '',                       // resolved lazily in getDetails
    source: AppSource.appImage,        // already in the contract enum
    version: meta.version,
    installedVersion: meta.version ?? 'unknown',
  )
  ```
  Every scanned file is installed by definition → `isInstalled == true`.

## 5. Filename heuristics (`parseFilename`)

`Name-Version-arch.AppImage` (also `_`/`-` separators, optional parts):
- Strip extension (case-insensitive).
- Trailing arch token (`x86_64`, `aarch64`, `i386`, …) → dropped.
- Middle version-ish token (`v1.2.3`, `1.2.3`, `continuous`) → version.
- Remainder → name, separators → spaces, e.g.
  `Kdenlive-24.08.3-x86_64.AppImage` → name `Kdenlive`, version `24.08.3`.
- Unparseable → name = basename minus extension, version = null.
Documented as heuristic; `.desktop` data wins when available.

## 6. Metadata extraction (`getDetails`)

1. Resolve `sha → path` via index; re-scan once if missing; still
   missing → `AppNotFoundException`.
2. `desktopPath = await transport.extractDesktop(path, tempDir)`.
   Parse keys: `Name`, `Comment`, `Version`, `X-AppImage-Version`,
   `Icon`, `Categories`, `Exec` (ignored — we launch the file).
3. Version fallback: `X-AppImage-Version` → `Version` → filename
   version → null. Never invent.
4. Icon: `transport.extractIcon(path, iconDir, iconName: desktop['Icon'])`
   → `~/.cache/libreapp-center/appimage-icons/<sha>.png`;
   `iconUrl` = absolute path, or `''` on any failure.
5. `AppDetails(app: …, description: comment ?? '', permissions: [],
   license: null, homepage: null)`; description prefixed with the
   honest unsandboxed disclosure:
   `"Runs unsandboxed with your user's full privileges. "`.

## 7. Error mapping

| Transport failure | StoreException |
|---|---|
| `HOME` unset / unreadable (isAvailable) | `false` (not an error) |
| dir missing during scan | skipped (normal) |
| `extractDesktop` fails | metadata falls back to filename heuristics |
| unknown sha in getDetails/install/remove | `AppNotFoundException` |
| copy fails (ENOSPC) | `DiskSpaceException` |
| copy fails (EACCES) | `PermissionException` |
| process exits non-zero | `UnknownStoreException(debugDetail, rawOutput)` |
| cancelled mid-copy | partial copy deleted → `Cancelled` |

Raw `AppImageCommandException` never escapes the backend.

## 8. Install / remove state machines

Install (`Preparing → Applying → Done`):
- `Preparing`: resolve sha → path; read manifest
  `~/.local/share/libreapp-center/appimage/<sha>.json`.
  Manifest exists → `Done(result: OperationResult(noop: true))`.
- `Applying`: copy (if source outside `~/Applications`) with
  sha256 verification of the copy; `chmod +x`; render + write
  `appimage-<slug>.desktop`; extract icon; write manifest.
  Progress: indeterminate (`Applying()`), file ops are fast.
- Cancel during copy → delete partial → `Cancelled` (≤2s).

Remove (`Preparing → Applying → Done`):
- `Preparing`: read manifest; missing manifest but sha in index →
  de-integrate best-effort (remove `appimage-<slug>.desktop` +
  cached icon if present); unknown sha → `AppNotFoundException`.
- `Applying`: delete desktop file, icon, manifest; if
  `manifest.copied` → delete the managed copy; else leave the user's
  file untouched. → `Done`.

Desktop file template (`appimage-<slug>.desktop`):
```ini
[Desktop Entry]
Type=Application
Name=<name>
Comment=<comment>
Exec="<managedPath>" %U
Icon=<iconAbsPath>
Categories=<categories>;
X-LibreStore-Backend=appimage
X-LibreStore-Identity=<sha256>
X-LibreStore-Managed=true
```
`slug` = lowercase alnum of name, truncated to 48 chars.

## 9. Search

```dart
Stream<AppInfo> search(String query) {
  // 1..200 chars (contract PRE). Build/refresh index, then:
  final q = query.toLowerCase();
  for (final e in index.values) {
    if (cancelled) break;
    if (e.name.toLowerCase().contains(q) ||
        basename(e.path).toLowerCase().contains(q)) {
      controller.add(e.toAppInfo());
    }
  }
}
```
Cancellation flag checked per directory during scan and per entry
during emit; `onCancel` sets it and closes. Local-only (no network).

## 10. Exam fixture plan

`StubAppimageTransport`: scripted `listDir` (two fake `.AppImage`
entries + a non-AppImage decoy), `readHead` (valid type-2 magic for
the fakes), `sha256Of` (fixed digests), `extractDesktop` (canned
`.desktop` text), file ops as in-memory map. Exam targets:
- `installTarget`: sha of stub app present in `~/Downloads`
  (adopt flow → copy).
- `installedTarget`: sha of stub app already in `~/Applications`
  with manifest (→ noop).
- `unknownTarget`: sha not in the stub index (→ typed).
Plus unit tests: magic classifier, filename parser, desktop parser,
version chain, manifest round-trip, desktop template.
