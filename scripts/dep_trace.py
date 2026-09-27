#!/usr/bin/env python3
"""dep_trace.py — the lever for the strangler-fig migration (ADR-003).

Scans every Dart file under packages/ and reports:
  1. VIOLATIONS: UI-layer files importing backend code directly
     (package:snapd, or files under lib/snapd|deb|packagekit|ratings).
     Each violation is one cut the migration must make.
  2. REVERSE VIOLATIONS: backend files importing UI code (also must die).
  3. MIGRATION MAP: proposed target package per directory.

Deterministic and rerunnable: same tree -> byte-identical report.
Usage: python3 scripts/dep_trace.py [--report FILE]

Exit code: 0 always (it reports; it does not judge). The exam judges.
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "packages")

IMPORT_RE = re.compile(r"""^import\s+['"]([^'"]+)['"]""")

BACKEND_DIRS = ("lib/snapd/", "lib/deb/", "lib/packagekit/")
RATINGS_MARKERS = ("lib/ratings/", "app_center_ratings_client")
UI_DIR_HINTS = ("lib/manage/", "lib/search/", "lib/explore/", "lib/apps/",
                "lib/games/", "lib/widgets/", "lib/about/", "lib/layout")
UI_NAME_HINTS = ("_page.dart", "_tile.dart", "_dialog.dart", "_field.dart",
                 "_bar.dart", "_card.dart", "l10n.dart")


def rel(path):
    return os.path.relpath(path, ROOT)


def layer_of(path):
    """Classify a file's home layer by location/name."""
    r = rel(path).replace(os.sep, "/")
    for d in BACKEND_DIRS:
        if d in r:
            return "backend"
    for m in RATINGS_MARKERS:
        if m in r:
            return "ratings"
    if "lib/appstream/" in r or "lib/gstreamer/" in r or "lib/drivers/" in r:
        return "system"  # host-side system services, not UI
    for d in UI_DIR_HINTS:
        if d in r:
            return "ui"
    for h in UI_NAME_HINTS:
        if r.endswith(h):
            return "ui"
    if "/lib/src/" in r or "lib/store/" in r or "lib/providers/" in r:
        return "host"
    return "other"


def is_backend_import(imp):
    if imp.startswith("package:snapd/"):
        return True
    # relative or package: import reaching into a backend dir
    return any(d.strip("lib/").strip("/") in imp.replace("package:app_center/", "")
               for d in ("snapd/", "deb/", "packagekit/")) and \
        ("snapd/" in imp or "deb/" in imp or "packagekit/" in imp)


def scan():
    files = []
    for dirpath, _, filenames in os.walk(PKG):
        for f in sorted(filenames):
            if f.endswith(".dart"):
                files.append(os.path.join(dirpath, f))
    files.sort()
    imports = {}  # path -> list of raw import strings
    for path in files:
        imps = []
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = IMPORT_RE.match(line.strip())
                if m:
                    imps.append(m.group(1))
        imports[path] = imps
    return files, imports


def main():
    report_path = None
    if "--report" in sys.argv:
        report_path = sys.argv[sys.argv.index("--report") + 1]

    files, imports = scan()
    layers = {p: layer_of(p) for p in files}

    violations = []       # ui -> backend
    reverse = []          # backend -> ui
    ratings_touch = []    # anything -> ratings
    snapd_direct = []     # anything importing package:snapd

    for path in files:
        src_layer = layers[path]
        for imp in imports[path]:
            if imp.startswith("package:snapd/"):
                snapd_direct.append((rel(path), imp))
            backend_hit = is_backend_import(imp)
            ratings_hit = any(m.replace("lib/", "") in imp or m in imp
                              for m in RATINGS_MARKERS)
            # resolve target layer of the import for cross-layer check
            tgt_layer = None
            if backend_hit:
                tgt_layer = "backend"
            elif ratings_hit:
                tgt_layer = "ratings"
            if tgt_layer and src_layer == "ui":
                (violations if tgt_layer == "backend" else ratings_touch).append(
                    (rel(path), imp))
            elif tgt_layer == "ui" or (src_layer in ("backend", "ratings")
                                       and tgt_layer is None and
                                       any(h in imp for h in UI_NAME_HINTS)):
                # l10n.dart is shared infra, not a UI-layering violation
                if "l10n.dart" in imp:
                    continue
                if src_layer in ("backend", "ratings", "system"):
                    reverse.append((rel(path), imp))
            if ratings_hit and src_layer not in ("ratings",):
                if (rel(path), imp) not in ratings_touch:
                    ratings_touch.append((rel(path), imp))

    # de-dup, sort for determinism
    violations = sorted(set(violations))
    reverse = sorted(set(reverse))
    ratings_touch = sorted(set(ratings_touch))
    snapd_direct = sorted(set(snapd_direct))

    layer_counts = defaultdict(int)
    for p in files:
        layer_counts[layers[p]] += 1

    out = []
    out.append("# dep_trace report — UI/backend coupling map")
    out.append("")
    out.append(f"Scanned {len(files)} Dart files under packages/.")
    out.append("")
    out.append("## Layer census")
    for layer in ("ui", "backend", "ratings", "system", "host", "other"):
        out.append(f"- {layer}: {layer_counts[layer]} files")
    out.append("")
    out.append(f"## VIOLATIONS: UI -> backend imports ({len(violations)})")
    out.append("Each line is one cut the strangler-fig migration must make.")
    for src, imp in violations:
        out.append(f"- `{src}` imports `{imp}`")
    out.append("")
    out.append(f"## REVERSE: backend/system -> UI imports ({len(reverse)})")
    for src, imp in reverse:
        out.append(f"- `{src}` imports `{imp}`")
    out.append("")
    out.append(f"## Ratings touchpoints ({len(ratings_touch)})")
    out.append("ADR-005: ratings degrade in Phase 0 — these imports go away or "
               "become graceful empty states.")
    for src, imp in ratings_touch:
        out.append(f"- `{src}` imports `{imp}`")
    out.append("")
    out.append(f"## Direct package:snapd importers ({len(snapd_direct)})")
    for src, imp in snapd_direct:
        out.append(f"- `{src}` imports `{imp}`")
    out.append("")
    out.append("## Proposed migration map (starting point, human to refine)")
    out.append("- `lib/snapd/` (non-UI files) -> `backend_snap`")
    out.append("- `lib/deb/`, `lib/packagekit/` -> `backend_deb`")
    out.append("- `lib/ratings/`, `packages/app_center_ratings_client` -> "
               "degraded per ADR-005 (shim or removal)")
    out.append("- `lib/appstream/` -> `store_host` metadata pipeline")
    out.append("- `lib/store/`, `lib/src/`, `lib/providers/` -> `store_host` or UI shell (triage per file)")
    out.append("- UI dirs (`manage/`, `search/`, `explore/`, `apps/`, `games/`, "
               "`widgets/`) -> `app_center` UI, via `store_contracts` only")
    out.append("- New: `backend_flatpak` (ADR-006, CLI wrapper, behind flag)")

    text = "\n".join(out) + "\n"
    if report_path:
        with open(report_path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {report_path}")
    else:
        print(text)


if __name__ == "__main__":
    main()
