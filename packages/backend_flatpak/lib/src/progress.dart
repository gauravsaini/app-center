/// Defensive parser for `flatpak(1)` progress lines.
///
/// Real-world shapes (flatpak 1.14/1.16):
///   `Downloading: 45%`
///   `[====>    ] Downloading: 45% (12.3 MB / 27.5 MB)`
///
/// Anything unrecognized returns null — the caller treats it as
/// indeterminate progress rather than guessing.
library;

class FlatpakProgress {
  const FlatpakProgress({
    required this.percent,
    this.doneBytes,
    this.totalBytes,
  });

  /// 0..100.
  final int percent;
  final int? doneBytes;
  final int? totalBytes;
}

final _percentRe = RegExp(r'(\d{1,3})\s*%');
final _bytesRe = RegExp(
  r'\(\s*([\d.]+\s*[KMGT]?B)\s*/\s*([\d.]+\s*[KMGT]?B)\s*\)',
  caseSensitive: false,
);
final _sizeRe = RegExp(r'^([\d.]+)\s*([KMGT]?)B$', caseSensitive: false);

int? _parseSize(String s) {
  final m = _sizeRe.firstMatch(s.trim());
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!);
  if (value == null) return null;
  const mult = {
    '': 1,
    'K': 1024,
    'M': 1024 * 1024,
    'G': 1024 * 1024 * 1024,
    'T': 1024 * 1024 * 1024 * 1024,
  };
  final k = m.group(2)!.toUpperCase();
  return (value * (mult[k] ?? 1)).round();
}

/// Parse one stdout line. Returns null when the line carries no progress.
FlatpakProgress? parseProgressLine(String line) {
  final pm = _percentRe.firstMatch(line);
  if (pm == null) return null;
  final percent = int.parse(pm.group(1)!).clamp(0, 100);
  final bm = _bytesRe.firstMatch(line);
  if (bm == null) return FlatpakProgress(percent: percent);
  return FlatpakProgress(
    percent: percent,
    doneBytes: _parseSize(bm.group(1)!),
    totalBytes: _parseSize(bm.group(2)!),
  );
}
