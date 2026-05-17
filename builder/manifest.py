#!/usr/bin/env python3
"""Génère un manifest JSON listant toutes les sources à télécharger avant build."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
import urllib.request

from entrypoint import (
    DEFAULT_THEMES,
    head_signature,
    prepare_theme,
)
from resolver import metrics_reset, metrics_snapshot
import urllib.request
import urllib.error


def geopf_preflight() -> tuple[bool, float | None]:
    """Vérifie si GeoPF est disponible sans ban avant de lancer les résolutions.

    Retourne (blocked, retry_after_seconds).
    """
    url = "https://data.geopf.fr/telechargement/capabilities"
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "geodock-index-builder"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return False, None
    except urllib.error.HTTPError as exc:
        if exc.code == 405:
            # Fallback GET léger
            req = urllib.request.Request(url, method="GET", headers={"Range": "bytes=0-1", "User-Agent": "geodock-index-builder"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                return False, None
        if exc.code == 429:
            ra = 0.0
            try:
                ra = float(exc.headers.get("Retry-After", "0"))
            except Exception:
                ra = 0.0
            return True, ra if ra > 0 else None
        return False, None
    except Exception:
        # En cas d'erreur réseau imprévue, on tente quand même (éviter faux positifs)
        return False, None


FALLBACK_DEPARTEMENTS = [
    *(f"{code:02d}" for code in range(1, 96) if code != 20),
    "2A",
    "2B",
    "971",
    "972",
    "973",
    "974",
    "975",
    "976",
    "977",
    "978",
    "984",
    "986",
    "987",
    "988",
]

# Overrides per theme (exclude codes without publications)
_THEME_EXCLUDES = {
    "parcel": {"975", "984", "986", "987", "988"},
    "poi": {"986", "987", "988"},
}

DEPARTEMENTS_CACHE_PATH = Path(os.getenv("DEPARTEMENTS_CACHE_PATH", "/out/departements-officiels.json"))
DEPARTEMENTS_API_URL = os.getenv("DEPARTEMENTS_API_URL", "https://geo.api.gouv.fr/departements")

MANIFEST_DEPARTEMENTS = os.getenv("MANIFEST_DEPARTEMENTS") or os.getenv("REFRESH_DEPARTEMENTS")
MANIFEST_FORCE_ALL = os.getenv("MANIFEST_FORCE_ALL", "0").lower() in {"1", "true", "yes"}

_DOM_CRS_MAPPING = {
    "971": "RGAF09UTM20",
    "972": "RGAF09UTM20",
    "973": "UTM22RGFG95",
    "974": "RGR92UTM40S",
    "975": "RGSPM06U21",
    "976": "RGM04UTM38S",
    "977": "RGAF09UTM20",
    "978": "RGAF09UTM20",
}

# Certains départements n'ont pas de diffusions Parcellaire (ex: 975, 984, 986-988)
_PARCEL_EXCLUDED = {"975", "984", "986", "987", "988"}

LOG_PREFIX = "[manifest]"


def log(message: str) -> None:
    print(f"{LOG_PREFIX} {message}", flush=True)  # noqa: T201


@dataclass(slots=True)
class SourceInfo:
    theme: str
    departement: str | None
    url: str
    etag: str | None
    updated: str | None
    kind: str | None = None
    error: str | None = None
    local_url: str | None = None

    def as_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "url": self.url,
            "etag": self.etag,
            "updated": self.updated,
        }
        if self.departement:
            data["departement"] = self.departement
        if self.kind:
            data["kind"] = self.kind
        if self.error:
            data["error"] = self.error
        if self.local_url:
            data["local_url"] = self.local_url
        return data


def _source_key(entry: dict[str, Any]) -> tuple[str, str | None]:
    return (str(entry.get("kind") or ""), entry.get("departement"))


def _current_block(entry: dict[str, Any]) -> dict[str, Any]:
    if isinstance(entry.get("current"), dict):
        block = dict(entry["current"])
    else:
        block = {
            "url": entry.get("url"),
            "etag": entry.get("etag"),
            "updated": entry.get("updated"),
            "seen_at": entry.get("seen_at"),
        }
    if entry.get("local_url") and not block.get("local_url"):
        block["local_url"] = entry.get("local_url")
    return block


def _signature(block: dict[str, Any]) -> str:
    return "|".join([
        block.get("etag") or "",
        block.get("updated") or "",
        block.get("url") or "",
    ])


def compute_manifest_signature(sources: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for entry in sources:
        if not isinstance(entry, dict):
            continue
        current = entry.get("current") if isinstance(entry.get("current"), dict) else entry
        parts.append(":".join([
            str(entry.get("kind") or entry.get("theme") or "manifest"),
            str(entry.get("departement") or ""),
            str(current.get("etag") or ""),
            str(current.get("updated") or ""),
            str(current.get("url") or ""),
            str(current.get("local_url") or entry.get("local_url") or ""),
            str(current.get("error") or entry.get("error") or ""),
        ]))
    return "|".join(parts)


def merge_previous_sources(
    new_sources: list[dict[str, Any]],
    old_sources: list[dict[str, Any]],
    generated_at: str | None,
) -> list[dict[str, Any]]:
    old_map = {_source_key(entry): entry for entry in old_sources if isinstance(entry, dict)}
    merged: list[dict[str, Any]] = []
    for entry in new_sources:
        if not isinstance(entry, dict):
            merged.append(entry)
            continue
        key = _source_key(entry)
        prev_entry = old_map.get(key)
        current = {
            "url": entry.get("url"),
            "etag": entry.get("etag"),
            "updated": entry.get("updated"),
            "seen_at": generated_at,
        }
        if entry.get("local_url"):
            current["local_url"] = entry.get("local_url")
        previous: dict[str, Any] | None = None
        if prev_entry:
            prev_current = _current_block(prev_entry)
            prev_prev = prev_entry.get("previous") if isinstance(prev_entry.get("previous"), dict) else None
            if _signature(prev_current) != _signature(current):
                previous = {
                    "url": prev_current.get("url"),
                    "etag": prev_current.get("etag"),
                    "updated": prev_current.get("updated"),
                }
                if prev_current.get("seen_at"):
                    previous["seen_at"] = prev_current.get("seen_at")
                if prev_current.get("local_url"):
                    previous["local_url"] = prev_current.get("local_url")
            elif prev_prev:
                previous = prev_prev
        entry["current"] = current
        if previous:
            entry["previous"] = previous
        # Backward-compatible aliases
        entry["url"] = current.get("url")
        entry["etag"] = current.get("etag")
        entry["updated"] = current.get("updated")
        merged.append(entry)
    return merged


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        if path.exists():
            return json.loads(path.read_text("utf-8"))
    except Exception:
        return None
    return None


def _artifact_url(path: Path, base_url: str | None, fallback_url: str | None = None) -> str:
    if fallback_url:
        return fallback_url
    if base_url:
        return f"{base_url.rstrip('/')}/{path.name}"
    return path.resolve().as_uri()


def _list_archives(output_dir: Path, theme: str) -> list[Path]:
    pattern = f"*index-{theme}-*.tar.gz"
    candidates = [p for p in output_dir.glob(pattern) if "-latest" not in p.name]
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates


def build_artifacts(output_dir: Path, theme: str, catalog: dict[str, Any]) -> dict[str, Any]:
    artifacts: dict[str, Any] = {}
    base_url = os.getenv("CATALOG_BASE_URL") or ""
    theme_catalog = catalog.get("themes", {}).get(theme, {}) if isinstance(catalog, dict) else {}
    archives = _list_archives(output_dir, theme)

    # Current (prefer catalog archive if available)
    current: dict[str, Any] | None = None
    archive_meta = theme_catalog.get("archive") if isinstance(theme_catalog, dict) else None
    if isinstance(archive_meta, dict) and archive_meta.get("path"):
        current_path = Path(str(archive_meta.get("path")))
        current = {
            "path": str(current_path),
            "filename": current_path.name,
            "url": _artifact_url(current_path, base_url, archive_meta.get("url")),
            "sha256": archive_meta.get("sha256"),
        }
    elif archives:
        current_path = archives[0]
        current = {
            "path": str(current_path),
            "filename": current_path.name,
            "url": _artifact_url(current_path, base_url),
        }
    if current:
        artifacts["current"] = current

    # Previous (second most recent archive)
    if len(archives) > 1:
        prev_path = archives[1]
        artifacts["previous"] = {
            "path": str(prev_path),
            "filename": prev_path.name,
            "url": _artifact_url(prev_path, base_url),
        }

    # Latest alias
    latest_meta = theme_catalog.get("latest") if isinstance(theme_catalog, dict) else None
    latest_path = None
    latest_url = None
    if isinstance(latest_meta, dict) and latest_meta.get("path"):
        latest_path = Path(str(latest_meta.get("path")))
        latest_url = latest_meta.get("url")
    else:
        alias_name = f"index-{theme}-latest.tar.gz"
        alias_path = output_dir / alias_name
        if alias_path.exists():
            latest_path = alias_path
    if latest_path:
        artifacts["latest_alias"] = {
            "path": str(latest_path),
            "filename": latest_path.name,
            "url": _artifact_url(latest_path, base_url, latest_url),
        }

    if archives:
        artifacts["archives"] = [
            {"path": str(p), "filename": p.name} for p in archives
        ]

    return artifacts


def fetch_official_departements() -> list[str]:
    try:
        with urllib.request.urlopen(DEPARTEMENTS_API_URL, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
        codes = sorted({str(item.get("code")) for item in payload if item.get("code")})
        if codes:
            try:
                DEPARTEMENTS_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
                DEPARTEMENTS_CACHE_PATH.write_text(json.dumps(codes, indent=2, ensure_ascii=False), "utf-8")
            except Exception:
                pass
            return codes
    except Exception:
        pass
    try:
        if DEPARTEMENTS_CACHE_PATH.exists():
            cached = json.loads(DEPARTEMENTS_CACHE_PATH.read_text("utf-8"))
            if isinstance(cached, list) and cached:
                return cached
    except Exception:
        pass
    return FALLBACK_DEPARTEMENTS


def departements_by_theme() -> dict[str, list[str]]:
    base = fetch_official_departements()
    mapping: dict[str, list[str]] = {}
    base_set = {code for code in base}
    for theme in DEFAULT_THEMES:
        excludes = _THEME_EXCLUDES.get(theme, set())
        valid = sorted(code for code in base_set if code not in excludes)
        mapping[theme] = valid
    return mapping


_DEPARTEMENTS_BY_THEME = departements_by_theme()


def themes_to_process() -> list[str]:
    raw = os.getenv("THEMES")
    if raw:
        values = [item.strip() for item in raw.split(",") if item.strip()]
        if values:
            return values
    return list(DEFAULT_THEMES)


def resolve_departements(theme: str, departments_env: list[str]) -> list[str]:
    base = _DEPARTEMENTS_BY_THEME.get(theme, FALLBACK_DEPARTEMENTS)
    if MANIFEST_DEPARTEMENTS:
        requested = [item.strip() for item in MANIFEST_DEPARTEMENTS.split(",") if item.strip()]
        return [code for code in base if code in requested]
    if departments_env and not MANIFEST_FORCE_ALL:
        requested = [item.strip() for item in departments_env if item.strip()]
        return [code for code in base if code in requested]
    return base


def replace_placeholders(template: str, dep: str, crs: str | None = None) -> str:
    result = template.replace("{dep}", dep if dep.startswith("D") else f"D{dep}")
    if crs:
        result = result.replace("{crs}", crs)
    return result


def _normalize_dep(dep: str) -> str:
    value = dep.strip().upper()
    if value.startswith("D"):
        value = value[1:]
    return value


def _format_dep_for_template(dep: str, with_prefix: bool = False) -> str:
    clean = _normalize_dep(dep)
    if with_prefix:
        if len(clean) == 2:
            return f"D0{clean}"
        return f"D{clean}"
    if clean.isdigit():
        return clean.zfill(2) if len(clean) <= 2 else clean
    return clean


def _crs_label_for_dep(dep: str, default: str | None = None) -> str:
    clean = _normalize_dep(dep)
    if len(clean) == 2:
        return "LAMB93"
    return _DOM_CRS_MAPPING.get(clean, default or "LAMB93")


def build_address_sources(env: dict[str, str], departments: list[str]) -> list[SourceInfo]:
    template = env.get("BAN_ADDOK_URL")
    results: list[SourceInfo] = []
    if not template:
        return results
    log(f"Résolution des adresses pour {len(departments)} département(s)")
    for dep in departments:
        dep_code = _format_dep_for_template(dep, with_prefix=False)
        url = template.replace("{dep}", dep_code)
        try:
            log(f"  HEAD address/{dep} -> {url}")
            etag, updated = head_signature(url)
            results.append(SourceInfo(theme="address", departement=dep, url=url, etag=etag, updated=updated))
        except (HTTPError, URLError) as exc:  # pragma: no cover - dépend du réseau
            log(f"  ERREUR address/{dep} -> {exc}")
            results.append(SourceInfo(theme="address", departement=dep, url=url, etag=None, updated=None, error=str(exc)))
        except Exception as exc:  # pragma: no cover
            log(f"  ERREUR address/{dep} -> {exc}")
            results.append(SourceInfo(theme="address", departement=dep, url=url, etag=None, updated=None, error=str(exc)))
    return results


def build_parcel_sources(env: dict[str, str], departments: list[str], crs: str | None) -> list[SourceInfo]:
    template = env.get("PARCELLAIRE_EXPRESS_URL")
    results: list[SourceInfo] = []
    if not template:
        return results
    log(f"Résolution du parcellaire pour {len(departments)} département(s)")
    for dep in departments:
        if dep in _PARCEL_EXCLUDED:
            log(f"  SKIP parcel/{dep} (not available)")
            continue
        dep_placeholder = _format_dep_for_template(dep, with_prefix=True)
        url = template.replace("{dep}", dep_placeholder)
        if "{crs}" in url:
            label = _crs_label_for_dep(dep, default=crs)
            url = url.replace("{crs}", label)
        try:
            log(f"  HEAD parcel/{dep} -> {url}")
            etag, updated = head_signature(url)
            results.append(SourceInfo(theme="parcel", departement=dep, url=url, etag=etag, updated=updated))
        except (HTTPError, URLError) as exc:  # pragma: no cover
            log(f"  ERREUR parcel/{dep} -> {exc}")
            results.append(SourceInfo(theme="parcel", departement=dep, url=url, etag=None, updated=None, error=str(exc)))
        except Exception as exc:  # pragma: no cover
            log(f"  ERREUR parcel/{dep} -> {exc}")
            results.append(SourceInfo(theme="parcel", departement=dep, url=url, etag=None, updated=None, error=str(exc)))
    return results


def build_poi_sources(env: dict[str, str], departments: list[str], crs: str | None) -> list[SourceInfo]:
    results: list[SourceInfo] = []
    admin_url = env.get("ADMIN_EXPRESS_URL")
    if admin_url:
        try:
            log(f"  HEAD poi/admin -> {admin_url}")
            etag, updated = head_signature(admin_url)
            results.append(SourceInfo(theme="poi", departement=None, url=admin_url, etag=etag, updated=updated, kind="admin"))
        except (HTTPError, URLError) as exc:  # pragma: no cover
            log(f"  ERREUR poi/admin -> {exc}")
            results.append(SourceInfo(theme="poi", departement=None, url=admin_url, etag=None, updated=None, kind="admin", error=str(exc)))
        except Exception as exc:  # pragma: no cover
            log(f"  ERREUR poi/admin -> {exc}")
            results.append(SourceInfo(theme="poi", departement=None, url=admin_url, etag=None, updated=None, kind="admin", error=str(exc)))
    bdtopo_template = env.get("BDTOPO_URL")
    if bdtopo_template:
        log(f"Résolution POI/BDTOPO pour {len(departments)} département(s)")
        for dep in departments:
            dep_placeholder = _format_dep_for_template(dep, with_prefix=True)
            url = bdtopo_template.replace("{dep}", dep_placeholder)
            if "{crs}" in url:
                label = _crs_label_for_dep(dep, default=crs)
                url = url.replace("{crs}", label)
            try:
                log(f"  HEAD poi/{dep} -> {url}")
                etag, updated = head_signature(url)
                results.append(SourceInfo(theme="poi", departement=dep, url=url, etag=etag, updated=updated, kind="bdtopo"))
            except (HTTPError, URLError) as exc:  # pragma: no cover
                log(f"  ERREUR poi/{dep} -> {exc}")
                results.append(SourceInfo(theme="poi", departement=dep, url=url, etag=None, updated=None, kind="bdtopo", error=str(exc)))
            except Exception as exc:  # pragma: no cover
                log(f"  ERREUR poi/{dep} -> {exc}")
                results.append(SourceInfo(theme="poi", departement=dep, url=url, etag=None, updated=None, kind="bdtopo", error=str(exc)))
    return results


def compute_manifest() -> dict[str, Any]:
    manifest: dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "themes": {}
    }
    themes = themes_to_process()
    log(f"Démarrage du manifest pour les thématiques: {', '.join(themes)}")
    for theme in themes:
        log(f"--- Thématique {theme} ---")
        try:
            sources, env, departments_env, crs = prepare_theme(theme)
        except Exception as exc:  # pragma: no cover - dépend du réseau
            manifest["themes"][theme] = {"error": str(exc)}
            log(f"Thématique {theme} interrompue: {exc}")
            continue

        departements = resolve_departements(theme, departments_env)
        log(f"{theme}: {len(departements)} département(s) ciblé(s)")
        theme_entry: dict[str, Any] = {
            "departements": departements,
            "crs": crs,
            "sources": [],
            "env": env,
        }

        if theme == "address":
            theme_entry["template"] = env.get("BAN_ADDOK_URL")
            theme_entry["sources"] = [info.as_dict() for info in build_address_sources(env, departements)]
        elif theme == "parcel":
            theme_entry["template"] = env.get("PARCELLAIRE_EXPRESS_URL")
            theme_entry["sources"] = [info.as_dict() for info in build_parcel_sources(env, departements, crs)]
        elif theme == "poi":
            theme_entry["templates"] = {
                "bdtopo": env.get("BDTOPO_URL"),
                "admin": env.get("ADMIN_EXPRESS_URL")
            }
            theme_entry["sources"] = [info.as_dict() for info in build_poi_sources(env, departements, crs)]
        else:
            theme_entry["sources"] = []

        theme_entry["signature"] = compute_manifest_signature(theme_entry["sources"])
        manifest["themes"][theme] = theme_entry

    return manifest


def main() -> None:
    output_path = os.getenv("MANIFEST_PATH", "/out/sources-manifest.json")
    # Manifest: on évite les HEAD de "probe" côté resolver/entrypoint
    os.environ.setdefault("RESOLVE_SKIP_PROBE_HEAD", "1")
    log(f"Chemin de sortie: {output_path}")
    # Pré-vol: ne pas démarrer si GeoPF impose un Retry-After
    blocked, wait_s = geopf_preflight()
    if blocked:
        when = datetime.now(timezone.utc).isoformat()
        print(f"[manifest][preflight] GeoPF bloque les requêtes (429). Retry-After={wait_s or '?'}s — arrêt immédiat.")  # noqa: T201
        # Écrit un manifest minimal avec stats pour audit
        minimal = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "themes": {},
            "stats": {
                "hits": 0,
                "ok": 0,
                "429": 1,
                "retry": 0,
                "elapsed_seconds": 0.0,
                "by_host": {"data.geopf.fr": {"hits": 1, "ok": 0, "429": 1, "retry": 0}},
                "preflight": {"blocked": True, "retry_after": wait_s, "at": when},
            },
        }
        destination = Path(output_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(minimal, indent=2, ensure_ascii=False), "utf-8")
        # Ecrit un marqueur de ban pour l'orchestrateur/ops
        try:
            out_dir = destination.parent
            ban_path = out_dir / "ban_until.txt"
            if wait_s:
                # Timestamp de fin de fenêtre estimée (UTC)
                from datetime import timedelta
                until = (datetime.now(timezone.utc) + timedelta(seconds=float(wait_s))).isoformat()
                ban_path.write_text(f"until={until}\nretry_after_seconds={wait_s}\n", "utf-8")
            else:
                ban_path.write_text(f"blocked_at={when}\nretry_after_seconds=unknown\n", "utf-8")
        except Exception:
            pass
        return
    metrics_reset()
    start = datetime.now(timezone.utc)
    manifest = compute_manifest()
    destination = Path(output_path)
    output_dir = destination.parent
    old_manifest_path = Path(os.getenv("OLD_MANIFEST_PATH", str(output_dir / "sources-manifest.old.json")))
    previous_manifest = _load_json(old_manifest_path)
    if previous_manifest:
        gen_at = manifest.get("generated_at")
        for theme, entry in manifest.get("themes", {}).items():
            old_sources = previous_manifest.get("themes", {}).get(theme, {}).get("sources", [])
            new_sources = entry.get("sources", []) if isinstance(entry, dict) else []
            if isinstance(new_sources, list) and isinstance(old_sources, list):
                entry["sources"] = merge_previous_sources(new_sources, old_sources, gen_at)
    catalog = _load_json(output_dir / "catalog.json") or {}
    for theme, entry in manifest.get("themes", {}).items():
        if isinstance(entry, dict):
            artifacts = build_artifacts(output_dir, theme, catalog)
            if artifacts:
                entry["artifacts"] = artifacts
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Ajout d'un bref bilan dans le JSON
    elapsed = (datetime.now(timezone.utc) - start).total_seconds()
    stats = metrics_snapshot() | {"elapsed_seconds": elapsed}
    manifest["stats"] = stats
    destination.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), "utf-8")
    log(f"Manifest écrit dans {destination}")
    # Bilan console lisible
    by_host = stats.get("by_host", {})
    lines = [
        f"hits={stats.get('hits', 0)} ok={stats.get('ok', 0)} 429={stats.get('429', 0)} retry={stats.get('retry', 0)} elapsed={elapsed:.2f}s",
    ]
    for host, m in by_host.items():
        lines.append(f" - {host}: hits={m.get('hits',0)} ok={m.get('ok',0)} 429={m.get('429',0)} retry={m.get('retry',0)}")
    for l in lines:
        print(f"[manifest][summary] {l}")  # noqa: T201


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:  # pragma: no cover
        sys.exit(130)
