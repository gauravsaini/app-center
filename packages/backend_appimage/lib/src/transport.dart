/// Transport abstraction: everything the AppImage backend needs from the
/// outside world.
///
/// [RealAppImageTransport] talks to the filesystem directly and reads
/// metadata through the AppImage's own runtime flags
/// (`--appimage-extract`, `--appimage-offset`) run on a private temp
/// *copy* — never the user's original file (research D1). Tests use
/// [StubAppimageTransport] (in `lib/testing.dart`) with canned responses.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// One directory entry from [AppImageTransport.listDir].
class DirEntry {
  const DirEntry({
    required this.name,
    required this.path,
    required this.isFile,
    required this.size,
    required this.mtimeMs,
    this.isExecutable = false,
  });

  final String name;
  final String path;
  final bool isFile;
  final int size;
  final int mtimeMs;

  /// Owner-execute bit. Prefilter hint only — [isAppImageMagic] decides.
  final bool isExecutable;
}

/// Transport-level failure. The backend maps these to [StoreException]
/// subtypes; they never escape the backend directly.
class AppImageCommandException implements Exception {
  const AppImageCommandException(this.args, this.exitCode, this.stderr);

  final List<String> args;
  final int exitCode;
  final String stderr;

  @override
  String toString() => 'appimage ${args.join(' ')} exited $exitCode: $stderr';
}

abstract class AppImageTransport {
  /// List a directory's files. A missing dir is normal → `[]`, never throws.
  Future<List<DirEntry>> listDir(String path);

  /// First [n] bytes of a file (the magic check). Throws
  /// [AppImageCommandException] when the file can't be read.
  Future<List<int>> readHead(String path, int n);

  /// Lowercase hex sha256 of the file, streamed — never whole-file in RAM.
  Future<String> sha256Of(String path);

  /// Extract the embedded `.desktop` file into [outDir] and return its
  /// path, or null when the AppImage carries none. Strategy:
  /// `unsquashfs` single-file extract when the binary exists, else
  /// copy → `chmod +x` the *copy* → `<copy> --appimage-extract` in a
  /// private temp dir. Never chmods / never executes the user's original.
  Future<String?> extractDesktop(String appImagePath, String outDir);

  /// Extract the icon named [iconName] into [outDir] and return its path,
  /// or null when unavailable. Empty [iconName] → null (nothing to find).
  Future<String?> extractIcon(
    String appImagePath,
    String outDir, {
    required String iconName,
  });

  Future<void> copyFile(String from, String to);

  Future<void> writeTextFile(String path, String content);

  /// Missing file → ok (normal, ADR-010).
  Future<void> deleteFile(String path);

  Future<void> chmodX(String path);

  /// Run a short process, return trimmed non-empty stdout lines.
  /// Throws [AppImageCommandException] on non-zero exit (127 when the
  /// binary is missing).
  Future<List<String>> runProcess(List<String> args, {String? workingDir});
}

/// Real transport: dart:io for files, the AppImage's own runtime flags
/// for metadata. Every operation that needs execute permission runs
/// against a private temp copy, never the user's file.
class RealAppImageTransport extends AppImageTransport {
  bool? _hasUnsquashfs;

  Future<bool> _unsquashfsPresent() async {
    final cached = _hasUnsquashfs;
    if (cached != null) return cached;
    try {
      final result = await Process.run('unsquashfs', ['-version']);
      _hasUnsquashfs = result.exitCode == 0;
    } on ProcessException {
      _hasUnsquashfs = false;
    }
    return _hasUnsquashfs!;
  }

  @override
  Future<List<DirEntry>> listDir(String path) async {
    final dir = Directory(path);
    try {
      if (!await dir.exists()) return const [];
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['test', '-d', path], 1, e.message);
    }
    final out = <DirEntry>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        // MVP: regular files only — symlinked AppImages are not followed.
        if (entity is! File) continue;
        late final FileStat stat;
        try {
          stat = await entity.stat();
        } on FileSystemException {
          continue; // unreadable entry — skip, don't fail the scan
        }
        if (stat.type != FileSystemEntityType.file) continue;
        out.add(
          DirEntry(
            name: _basename(entity.path),
            path: entity.path,
            isFile: true,
            size: stat.size,
            mtimeMs: stat.modified.millisecondsSinceEpoch,
            isExecutable: (stat.mode & 0x40) != 0, // S_IXUSR
          ),
        );
      }
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['ls', path], 1, e.message);
    }
    return out;
  }

  @override
  Future<List<int>> readHead(String path, int n) async {
    try {
      final raf = await File(path).open(mode: FileMode.read);
      try {
        return await raf.read(n);
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['head', '-c', '$n', path], 1, e.message);
    }
  }

  @override
  Future<String> sha256Of(String path) async {
    try {
      final digest = await sha256.bind(File(path).openRead()).single;
      return digest.toString();
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['sha256sum', path], 1, e.message);
    }
  }

  @override
  Future<String?> extractDesktop(String appImagePath, String outDir) async {
    final tree = await _extractTree(appImagePath, [
      '*.desktop',
      'usr/share/applications/*.desktop',
    ]);
    try {
      final found = _findDesktops(tree.root);
      if (found.isEmpty) return null;
      await Directory(outDir).create(recursive: true);
      final dest = '$outDir/${_basename(found.first)}';
      await File(found.first).copy(dest);
      return dest;
    } on FileSystemException catch (e) {
      throw AppImageCommandException(
        ['extract-desktop', appImagePath],
        1,
        e.message,
      );
    } finally {
      await tree.dispose();
    }
  }

  @override
  Future<String?> extractIcon(
    String appImagePath,
    String outDir, {
    required String iconName,
  }) async {
    if (iconName.isEmpty) return null;
    final tree = await _extractTree(appImagePath, [
      '$iconName.png',
      '$iconName.svg',
      '.DirIcon',
      'usr/share/icons/hicolor/*/apps/$iconName.*',
      'usr/share/pixmaps/$iconName.*',
    ]);
    try {
      final pick = _pickIcon(tree.root, iconName);
      if (pick == null) return null;
      await Directory(outDir).create(recursive: true);
      final dest = '$outDir/$iconName${_extensionOf(pick)}';
      await File(pick).copy(dest);
      return dest;
    } on FileSystemException catch (e) {
      throw AppImageCommandException(
        ['extract-icon', appImagePath],
        1,
        e.message,
      );
    } finally {
      await tree.dispose();
    }
  }

  @override
  Future<void> copyFile(String from, String to) async {
    try {
      await Directory(_dirname(to)).create(recursive: true);
      await File(from).copy(to);
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['cp', from, to], 1, e.message);
    }
  }

  @override
  Future<void> writeTextFile(String path, String content) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['write', path], 1, e.message);
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      await file.delete();
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['rm', path], 1, e.message);
    }
  }

  @override
  Future<void> chmodX(String path) => _chmod(path);

  @override
  Future<List<String>> runProcess(
    List<String> args, {
    String? workingDir,
  }) async {
    late final ProcessResult result;
    try {
      result = await Process.run(
        args.first,
        args.sublist(1),
        workingDirectory: workingDir,
      );
    } on ProcessException catch (e) {
      throw AppImageCommandException(args, 127, e.message);
    }
    if (result.exitCode != 0) {
      throw AppImageCommandException(
        args,
        result.exitCode,
        '${result.stderr}'.trim(),
      );
    }
    return '${result.stdout}'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Materialize the squashfs payload into a fresh private temp dir.
  /// The caller owns [TempTree.dispose]. The user's original file is only
  /// ever *copied*; the copy alone is chmod'd and executed.
  Future<_TempTree> _extractTree(
    String appImagePath,
    List<String> selective,
  ) async {
    late final Directory tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('libreappimage-');
    } on FileSystemException catch (e) {
      throw AppImageCommandException(['mktemp', appImagePath], 1, e.message);
    }
    try {
      final copyPath = '${tmp.path}/payload.AppImage';
      try {
        await File(appImagePath).copy(copyPath);
      } on FileSystemException catch (e) {
        throw AppImageCommandException(
          ['cp', appImagePath, copyPath],
          1,
          e.message,
        );
      }
      await _chmod(copyPath);
      // Fast path: selective unsquashfs using the payload offset.
      if (await _unsquashfsPresent()) {
        try {
          final offset = await _appimageOffset(copyPath);
          final selDir = Directory('${tmp.path}/selective');
          await selDir.create();
          final result = await Process.run('unsquashfs', [
            '-f',
            '-d',
            selDir.path,
            '-o',
            '$offset',
            copyPath,
            ...selective,
          ]);
          if (result.exitCode == 0) return _TempTree(tmp, selDir.path);
          // else fall through to full extraction
        } on AppImageCommandException {
          // fall through to full extraction
        }
      }
      // Universal path: the runtime's own userspace squashfs reader.
      // Needs no FUSE; writes ./squashfs-root under workingDirectory.
      final result = await Process.run(copyPath, [
        '--appimage-extract',
      ], workingDirectory: tmp.path);
      if (result.exitCode != 0) {
        throw AppImageCommandException(
          [copyPath, '--appimage-extract'],
          result.exitCode,
          '${result.stderr}'.trim(),
        );
      }
      return _TempTree(tmp, '${tmp.path}/squashfs-root');
    } on AppImageCommandException {
      await _deleteQuietly(tmp);
      rethrow;
    } on FileSystemException catch (e) {
      await _deleteQuietly(tmp);
      throw AppImageCommandException(['extract', appImagePath], 1, e.message);
    }
  }

  Future<int> _appimageOffset(String copyPath) async {
    late final ProcessResult result;
    try {
      result = await Process.run(copyPath, ['--appimage-offset']);
    } on ProcessException catch (e) {
      throw AppImageCommandException(
        [copyPath, '--appimage-offset'],
        127,
        e.message,
      );
    }
    if (result.exitCode != 0) {
      throw AppImageCommandException(
        [copyPath, '--appimage-offset'],
        result.exitCode,
        '${result.stderr}'.trim(),
      );
    }
    final offset = int.tryParse('${result.stdout}'.trim());
    if (offset == null) {
      throw AppImageCommandException(
        [copyPath, '--appimage-offset'],
        result.exitCode,
        'unparseable offset: ${result.stdout}',
      );
    }
    return offset;
  }

  Future<void> _chmod(String path) async {
    final result = await Process.run('chmod', ['+x', path]);
    if (result.exitCode != 0) {
      throw AppImageCommandException(
        ['chmod', '+x', path],
        result.exitCode,
        '${result.stderr}'.trim(),
      );
    }
  }

  Future<void> _deleteQuietly(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // best effort — temp dirs must never fail an operation
    }
  }

  /// Payload-root `*.desktop` first, then `usr/share/applications/`.
  List<String> _findDesktops(String root) {
    final found = <String>[];
    final top = Directory(root);
    if (top.existsSync()) {
      for (final e in top.listSync(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.desktop')) {
          found.add(e.path);
        }
      }
    }
    final apps = Directory('$root/usr/share/applications');
    if (apps.existsSync()) {
      for (final e in apps.listSync(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.desktop')) {
          found.add(e.path);
        }
      }
    }
    return found;
  }

  /// Icon lookup order (research §6): top-level `<Icon>.png`/`.svg`,
  /// `.DirIcon`, hicolor tree, pixmaps. Prefers the `Icon=`-named file,
  /// then SVG, then the largest sane PNG (IHDR size, no ImageMagick).
  String? _pickIcon(String root, String iconName) {
    final cands = <_IconCand>[];
    void consider(String path) {
      final file = File(path);
      if (!file.existsSync()) return;
      final lower = path.toLowerCase();
      final isSvg = lower.endsWith('.svg');
      var isPng = lower.endsWith('.png');
      if (!isSvg && !isPng) {
        // Extensionless (e.g. .DirIcon) — sniff the PNG magic.
        isPng = _hasPngMagic(file);
        if (!isPng) return;
      }
      final base = _basename(path);
      cands.add(
        _IconCand(
          path,
          isSvg: isSvg,
          area: isSvg ? 0 : _pngArea(file),
          exactName: base == '$iconName.png' || base == '$iconName.svg',
        ),
      );
    }

    consider('$root/$iconName.png');
    consider('$root/$iconName.svg');
    consider('$root/.DirIcon');
    final hicolor = Directory('$root/usr/share/icons/hicolor');
    if (hicolor.existsSync()) {
      for (final sizeDir in hicolor.listSync(followLinks: false)) {
        if (sizeDir is! Directory) continue;
        final appsDir = Directory('${sizeDir.path}/apps');
        if (!appsDir.existsSync()) continue;
        for (final e in appsDir.listSync(followLinks: false)) {
          if (e is File && _basename(e.path).startsWith(iconName)) {
            consider(e.path);
          }
        }
      }
    }
    final pixmaps = Directory('$root/usr/share/pixmaps');
    if (pixmaps.existsSync()) {
      for (final e in pixmaps.listSync(followLinks: false)) {
        if (e is File && _basename(e.path).startsWith(iconName)) {
          consider(e.path);
        }
      }
    }
    if (cands.isEmpty) return null;
    cands.sort((a, b) {
      if (a.exactName != b.exactName) return a.exactName ? -1 : 1;
      if (a.isSvg != b.isSvg) return a.isSvg ? -1 : 1;
      return b.area.compareTo(a.area);
    });
    return cands.first.path;
  }

  bool _hasPngMagic(File file) {
    try {
      final raf = file.openSync(mode: FileMode.read);
      try {
        final head = raf.readSync(8);
        return head.length == 8 &&
            head[0] == 0x89 &&
            head[1] == 0x50 &&
            head[2] == 0x4E &&
            head[3] == 0x47 &&
            head[4] == 0x0D &&
            head[5] == 0x0A &&
            head[6] == 0x1A &&
            head[7] == 0x0A;
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  /// Pixel area from the PNG IHDR header; 0 when unreadable or insane.
  int _pngArea(File file) {
    try {
      final raf = file.openSync(mode: FileMode.read);
      try {
        final head = raf.readSync(26);
        if (head.length < 26 || !_isPng(head)) return 0;
        final w = _u32be(head, 16);
        final h = _u32be(head, 20);
        if (w == 0 || h == 0 || w > 4096 || h > 4096) return 0;
        return w * h;
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return 0;
    }
  }

  bool _isPng(List<int> head) =>
      head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47;

  int _u32be(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
}

class _IconCand {
  _IconCand(
    this.path, {
    required this.isSvg,
    required this.area,
    required this.exactName,
  });

  final String path;
  final bool isSvg;
  final int area;
  final bool exactName;
}

class _TempTree {
  _TempTree(this.dir, this.root);

  final Directory dir;
  final String root;

  Future<void> dispose() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // best effort
    }
  }
}

String _basename(String path) {
  final idx = path.lastIndexOf('/');
  return idx < 0 ? path : path.substring(idx + 1);
}

String _dirname(String path) {
  final idx = path.lastIndexOf('/');
  return idx < 0 ? '.' : path.substring(0, idx);
}

/// Extension including the dot, lowercased; `.png` for extensionless
/// files (e.g. `.DirIcon`).
String _extensionOf(String path) {
  final base = _basename(path);
  final idx = base.lastIndexOf('.');
  if (idx <= 0) return '.png';
  return base.substring(idx).toLowerCase();
}
