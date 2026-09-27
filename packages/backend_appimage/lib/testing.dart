/// Scripted [AppImageTransport] for tests. Never touches the live system.
///
/// In-memory filesystem + canned magic bytes (`AI\x02` at offset 8),
/// fixed sha256 digests, a canned `.desktop` file, and a fake PNG icon.
///
/// Import via `package:backend_appimage/testing.dart` — kept out of the
/// main barrel so production code never depends on it.
///
/// Fixtures:
/// - `~/Downloads/TestApp-1.2.3-x86_64.AppImage` → [installTargetSha]:
///   the adopt flow (copy into `~/Applications`).
/// - `~/Applications/ManagedApp-2.0-x86_64.AppImage` → [installedTargetSha],
///   with a seeded install manifest → idempotent `Done(noop: true)`.
/// - `~/Downloads/notes.txt` and `~/.local/bin/tool` (ELF, no AppImage
///   magic): decoys the scan must reject.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:backend_appimage/src/transport.dart';

class _StubFile {
  _StubFile({required this.bytes, this.isExecutable = false, this.mtimeMs = 0});

  List<int> bytes;
  bool isExecutable;
  int mtimeMs;
}

class StubAppimageTransport extends AppImageTransport {
  StubAppimageTransport() : home = Platform.environment['HOME'] ?? '' {
    _seed();
  }

  /// sha256 of the stub install-target AppImage.
  static const installTargetSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  /// sha256 of the stub already-managed AppImage.
  static const installedTargetSha =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  final String home;

  /// Simulated copy duration — long enough for the cancel-mid-copy test
  /// to land inside it, short enough to keep the suite fast.
  Duration copyDelay = const Duration(milliseconds: 600);

  final Map<String, _StubFile> _files = {};
  final Map<String, String> _digests = {};

  /// Test hook: does the in-memory filesystem contain [path]?
  bool exists(String path) => _files.containsKey(path);

  String _p(String suffix) => '$home$suffix';

  static String _basename(String path) {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? path : path.substring(idx + 1);
  }

  void _seed() {
    _addAppImage(
      _p('/Downloads/TestApp-1.2.3-x86_64.AppImage'),
      installTargetSha,
      isExecutable: true,
    );
    _addAppImage(
      _p('/Applications/ManagedApp-2.0-x86_64.AppImage'),
      installedTargetSha,
      isExecutable: true,
    );
    // Seeded install manifest → the idempotent-noop fixture.
    _files[_p(
      '/.local/share/libreapp-center/appimage/$installedTargetSha.json',
    )] = _StubFile(
      bytes: utf8.encode(
        jsonEncode({
          'sourcePath': _p('/Applications/ManagedApp-2.0-x86_64.AppImage'),
          'managedPath': _p('/Applications/ManagedApp-2.0-x86_64.AppImage'),
          'copied': false,
          'desktopFile': 'appimage-managedapp.desktop',
        }),
      ),
    );
    // Decoys: plain text, and an ELF binary without AppImage magic.
    _files[_p('/Downloads/notes.txt')] = _StubFile(
      bytes: utf8.encode('just some notes\n'),
    );
    _files[_p('/.local/bin/tool')] = _StubFile(
      bytes: [0x7F, 0x45, 0x4C, 0x46, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      isExecutable: true,
    );
  }

  void _addAppImage(String path, String sha, {bool isExecutable = false}) {
    final bytes = List<int>.filled(64, 0);
    bytes[0] = 0x7F; // ELF magic
    bytes[1] = 0x45; // 'E'
    bytes[2] = 0x4C; // 'L'
    bytes[3] = 0x46; // 'F'
    bytes[8] = 0x41; // 'A'
    bytes[9] = 0x49; // 'I'
    bytes[10] = 0x02; // AI\x02 — type 2
    _files[path] = _StubFile(
      bytes: bytes,
      isExecutable: isExecutable,
      mtimeMs: 1759000000000,
    );
    _digests[path] = sha;
  }

  @override
  Future<List<DirEntry>> listDir(String path) async {
    final prefix = path.endsWith('/') ? path : '$path/';
    final out = <DirEntry>[];
    for (final e in _files.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final rest = e.key.substring(prefix.length);
      if (rest.contains('/')) continue; // non-recursive, like the real one
      out.add(
        DirEntry(
          name: rest,
          path: e.key,
          isFile: true,
          size: e.value.bytes.length,
          mtimeMs: e.value.mtimeMs,
          isExecutable: e.value.isExecutable,
        ),
      );
    }
    return out;
  }

  @override
  Future<List<int>> readHead(String path, int n) async {
    final f = _files[path];
    if (f == null) {
      throw AppImageCommandException(['head', path], 1, 'stub: no $path');
    }
    return f.bytes.take(n).toList();
  }

  @override
  Future<String> sha256Of(String path) async {
    final sha = _digests[path];
    if (sha == null) {
      throw AppImageCommandException(
        ['sha256sum', path],
        1,
        'stub: no digest for $path',
      );
    }
    return sha;
  }

  @override
  Future<String?> extractDesktop(String appImagePath, String outDir) async {
    if (!_files.containsKey(appImagePath)) return null;
    final stem = _basename(
      appImagePath,
    ).replaceAll(RegExp(r'\.appimage$', caseSensitive: false), '');
    final dest = '$outDir/$stem.desktop';
    _files[dest] = _StubFile(bytes: utf8.encode(_cannedDesktop));
    return dest;
  }

  @override
  Future<String?> extractIcon(
    String appImagePath,
    String outDir, {
    required String iconName,
  }) async {
    if (!_files.containsKey(appImagePath) || iconName.isEmpty) return null;
    final dest = '$outDir/$iconName.png';
    _files[dest] = _StubFile(bytes: _fakePng);
    return dest;
  }

  @override
  Future<void> copyFile(String from, String to) async {
    final src = _files[from];
    if (src == null) {
      throw AppImageCommandException(['cp', from, to], 1, 'stub: no $from');
    }
    if (copyDelay > Duration.zero) {
      await Future<void>.delayed(copyDelay);
    }
    _files[to] = _StubFile(
      bytes: List<int>.from(src.bytes),
      isExecutable: src.isExecutable,
      mtimeMs: src.mtimeMs,
    );
    final digest = _digests[from];
    if (digest != null) _digests[to] = digest;
  }

  @override
  Future<void> writeTextFile(String path, String content) async {
    _files[path] = _StubFile(bytes: utf8.encode(content));
  }

  @override
  Future<void> deleteFile(String path) async {
    _files.remove(path); // missing → ok
    _digests.remove(path);
  }

  @override
  Future<void> chmodX(String path) async {
    final f = _files[path];
    if (f == null) {
      throw AppImageCommandException(['chmod', path], 1, 'stub: no $path');
    }
    f.isExecutable = true;
  }

  /// The canned `.desktop` the stub "extracts". `X-AppImage-Version`
  /// deliberately differs from the filename version (9.9.9 vs 1.2.3)
  /// so tests can prove the fallback chain's precedence.
  static const _cannedDesktop = '''
[Desktop Entry]
Type=Application
Name=Test App
Comment=A test AppImage
Exec=testapp
Icon=testapp
Categories=Utility;
X-AppImage-Version=9.9.9
''';

  /// Minimal fake PNG: valid 8-byte signature, zeroed body.
  static final _fakePng = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...List<int>.filled(92, 0),
  ];
}
