#!/usr/bin/env python3
"""feature_map_check.py — the lever that keeps FEATURE_MAP.md honest.

Parses route constants out of StoreRoutes (store_routes.dart) and checks
that every one has a `Route:` entry in docs/FEATURE_MAP.md, and that no
map entry references a route that doesn't exist.

Deterministic. Rerun: python3 scripts/feature_map_check.py
Exit 0 = map covers all routes. Exit 1 = drift found (fix the map).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROUTES_FILE = os.path.join(
    ROOT, "packages/app_center/lib/store/store_routes.dart")
MAP_FILE = os.path.join(ROOT, "docs/FEATURE_MAP.md")

ROUTE_RE = re.compile(r"""static const \w+ = '([^']+)'""")
MAP_ROUTE_RE = re.compile(r"""^\s*-\s*\*\*Route:\*\*\s*`?([^`\s(]+)""",
                            re.MULTILINE)


def main():
    with open(ROUTES_FILE, encoding="utf-8") as fh:
        code_routes = set(ROUTE_RE.findall(fh.read()))
    # strip query strings: '/search?query=x' -> '/search'
    code_routes = {r.split("?")[0] for r in code_routes}

    with open(MAP_FILE, encoding="utf-8") as fh:
        map_text = fh.read()
    map_routes = set(MAP_ROUTE_RE.findall(map_text))
    map_routes = {r.split("?")[0] for r in map_routes}

    missing = sorted(code_routes - map_routes)
    orphaned = sorted(map_routes - code_routes)

    ok = True
    if missing:
        ok = False
        print("MISSING from FEATURE_MAP.md:")
        for r in missing:
            print(f"  - {r}")
    if orphaned:
        ok = False
        print("ORPHANED in FEATURE_MAP.md (no such route in code):")
        for r in orphaned:
            print(f"  - {r}")
    if ok:
        print(f"OK: {len(code_routes)} routes, all mapped.")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
