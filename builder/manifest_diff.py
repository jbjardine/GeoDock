#!/usr/bin/env python3
"""Compare two manifests and output which themes/departements changed.

Usage:
  python builder/manifest_diff.py --old /out/sources-manifest.old.json --new /out/sources-manifest.json

  --write-out writes:
    /out/changed-address.txt
    /out/changed-parcel.txt
    /out/changed-poi.txt
    /out/poi-admin-changed.txt
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def source_signature(src: dict) -> Tuple[str, str, str]:
    current = src.get("current") if isinstance(src.get("current"), dict) else src
    return (
        str(current.get("url") or ""),
        str(current.get("etag") or ""),
        str(current.get("updated") or ""),
    )


def build_index(manifest: dict, themes: Iterable[str]) -> Dict[str, Dict[str, Dict[str, Tuple[str, str, str]]]]:
    index: Dict[str, Dict[str, Dict[str, Tuple[str, str, str]]]] = {}
    for theme in themes:
        theme_sources = manifest.get("themes", {}).get(theme, {}).get("sources", [])
        per_kind: Dict[str, Dict[str, Tuple[str, str, str]]] = defaultdict(dict)
        for src in theme_sources:
            kind = src.get("kind")
            dep = src.get("departement") or ""
            per_kind[str(kind)][str(dep)] = source_signature(src)
        index[theme] = per_kind
    return index


def diff_manifests(old: dict, new: dict, themes: Iterable[str]) -> Dict[str, List[str]]:
    out: Dict[str, List[str]] = {t: [] for t in themes}
    old_index = build_index(old, themes)
    new_index = build_index(new, themes)

    for theme in themes:
        all_kinds = set(old_index.get(theme, {}).keys()) | set(new_index.get(theme, {}).keys())
        for kind in all_kinds:
            old_deps = old_index.get(theme, {}).get(kind, {})
            new_deps = new_index.get(theme, {}).get(kind, {})
            all_deps = set(old_deps.keys()) | set(new_deps.keys())
            for dep in all_deps:
                if old_deps.get(dep) != new_deps.get(dep):
                    if dep and dep not in out[theme]:
                        out[theme].append(dep)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--old", dest="old_path", default=os.getenv("OLD_MANIFEST_PATH", "/out/sources-manifest.old.json"))
    parser.add_argument("--new", dest="new_path", default=os.getenv("MANIFEST_PATH", "/out/sources-manifest.json"))
    parser.add_argument("--themes", default=os.getenv("THEMES", "address,parcel,poi"))
    parser.add_argument("--format", default="text")
    parser.add_argument("--write-out", action="store_true")
    args = parser.parse_args()

    themes = [t.strip() for t in args.themes.split(",") if t.strip()]
    old_manifest = load_manifest(Path(args.old_path))
    new_manifest = load_manifest(Path(args.new_path))
    changes = diff_manifests(old_manifest, new_manifest, themes)

    if args.format == "json":
        print(json.dumps(changes, indent=2))
    else:
        for theme, deps in changes.items():
            deps_sorted = ",".join(sorted(deps))
            print(f"{theme}: {deps_sorted}")

    if args.write_out:
        out_dir = Path(os.getenv("OUT_DIR", Path(args.new_path).parent))
        out_dir.mkdir(parents=True, exist_ok=True)
        for theme, deps in changes.items():
            out_path = out_dir / f"changed-{theme}.txt"
            with out_path.open("w", encoding="utf-8") as fh:
                fh.write(",".join(sorted(deps)))
        if "poi" in changes:
            out_path = out_dir / "poi-admin-changed.txt"
            if "" in changes["poi"]:
                out_path.write_text("1")
            elif out_path.exists():
                out_path.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
