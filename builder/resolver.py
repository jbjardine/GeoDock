"""Résolution des flux Atom GEO plateforme pour les jeux IGNF.

Ce module est adapté de ``scripts/geopf_resolver.py`` du dépôt principal
``geodock_dev`` afin d'être embarqué dans l'image ``geodock-index-builder``.
"""

from __future__ import annotations

import os
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from typing import Iterable

BASE = "https://data.geopf.fr/telechargement"
NS_ATOM = {"atom": "http://www.w3.org/2005/Atom"}

_REQUEST_INTERVAL = float(os.getenv("GEOPF_REQUEST_INTERVAL", "1.5"))
_LAST_REQUEST_TS = 0.0
_VERBOSE = os.getenv("RESOLVER_VERBOSE", "1").lower() not in {"0", "false", "no"}
_DEBUG = os.getenv("RESOLVER_DEBUG", "0").lower() in {"1", "true", "yes"}
_VERIFY_HEAD = os.getenv("RESOLVER_VERIFY_HEAD", "0").lower() in {"1", "true", "yes"}
_CACHE_ENABLED = os.getenv("GEOPF_CACHE", "1").lower() not in {"0", "false", "no"}
_CACHE_PATH = Path(
    os.getenv(
        "GEOPF_CACHE_PATH",
        str((Path.home() / ".cache" / "geodock" / "geopf-cache.json").resolve()),
    )
)
_CACHE_TTL = max(0, int(os.getenv("GEOPF_CACHE_TTL", "86400")))

_cache_store: dict[str, dict[str, str]] = {}
_cache_loaded = False
_REQ_SEQ = 0
_ABORT_ON_429 = os.getenv("GEOPF_ABORT_ON_429", "1").lower() in {"1", "true", "yes"}


def _ts() -> str:
    return datetime.now().isoformat(timespec="milliseconds")

def _log(message: str) -> None:
    if _VERBOSE:
        print(f"[resolver] {_ts()} {message}", flush=True)  # noqa: T201


def _debug(message: str) -> None:
    if _DEBUG:
        print(f"[resolver][debug] {_ts()} {message}", flush=True)  # noqa: T201


def next_req_id() -> int:
    global _REQ_SEQ
    _REQ_SEQ += 1
    return _REQ_SEQ


def http_log(kind: str, url: str, **fields) -> None:
    if not _VERBOSE:
        return
    extras = " ".join(f"{k}={v}" for k, v in fields.items()) if fields else ""
    print(f"[http] {_ts()} {kind} {url} {extras}".rstrip(), flush=True)  # noqa: T201
    # -- metrics -----------------------------------------------------------
    try:
        host = urlparse(url).netloc or ""
        if host:
            m = _METRICS.setdefault("by_host", {}).setdefault(host, {"hits": 0, "ok": 0, "429": 0, "retry": 0})
        else:
            m = {"hits": 0, "ok": 0, "429": 0, "retry": 0}
        if " GET" in kind or " HEAD" in kind:
            _METRICS["hits"] += 1
            m["hits"] += 1
        if " 200" in kind or "HEAD_OK" in kind:
            _METRICS["ok"] += 1
            m["ok"] += 1
        status = str(fields.get("status", ""))
        if status == "429":
            _METRICS["429"] += 1
            m["429"] += 1
        if "RETRY" in kind:
            _METRICS["retry"] += 1
            m["retry"] += 1
    except Exception:  # pragma: no cover - robuste
        pass


# -- metrics store ---------------------------------------------------------
_METRICS: dict = {"hits": 0, "ok": 0, "429": 0, "retry": 0, "by_host": {}}


def metrics_reset() -> None:
    _METRICS.clear()
    _METRICS.update({"hits": 0, "ok": 0, "429": 0, "retry": 0, "by_host": {}})


def metrics_snapshot() -> dict:
    # return a shallow copy
    snap = {k: (v.copy() if isinstance(v, dict) else v) for k, v in _METRICS.items()}
    return snap


def _throttle() -> None:
    global _LAST_REQUEST_TS
    delta = time.time() - _LAST_REQUEST_TS
    if delta < _REQUEST_INTERVAL:
        wait = _REQUEST_INTERVAL - delta
        if wait > 0:
            _debug(f"throttle since_last={delta:.3f}s wait={wait:.3f}s target={_REQUEST_INTERVAL:.3f}s")
            time.sleep(wait)
    else:
        _debug(f"throttle since_last={delta:.3f}s wait=0.000s target={_REQUEST_INTERVAL:.3f}s")
    _LAST_REQUEST_TS = time.time()


def _load_cache() -> None:
    global _cache_loaded
    if _cache_loaded or not _CACHE_ENABLED:
        return
    try:
        if _CACHE_PATH.exists():
            import json

            data = json.loads(_CACHE_PATH.read_text("utf-8"))
            if isinstance(data, dict):
                _cache_store.update({str(k): dict(v) for k, v in data.items() if isinstance(v, dict)})
                _debug(f"cache chargé ({len(_cache_store)} entrées)")
    except Exception as exc:  # pragma: no cover - robustesse
        _debug(f"cache lecture échouée ({exc})")
    _cache_loaded = True


def _save_cache() -> None:
    if not _CACHE_ENABLED:
        return
    try:
        import json

        _CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        _CACHE_PATH.write_text(json.dumps(_cache_store, indent=2, ensure_ascii=False), "utf-8")
        _debug("cache persisté")
    except Exception as exc:  # pragma: no cover - robustesse
        _debug(f"cache écriture échouée ({exc})")


def _cache_key(resource: str, zone: str, tag: str | None = None) -> str:
    suffix = f":{tag}" if tag else ""
    return f"{resource}:{zone}{suffix}"


def _cache_get(key: str) -> dict[str, str] | None:
    if not _CACHE_ENABLED:
        return None
    _load_cache()
    entry = _cache_store.get(key)
    if not entry:
        return None
    ts = float(entry.get("ts", "0"))
    if _CACHE_TTL and (time.time() - ts) > _CACHE_TTL:
        _debug(f"cache expiré pour {key}")
        return None
    _debug(f"cache hit {key}")
    return entry


def _cache_put(key: str, payload: dict[str, str]) -> None:
    if not _CACHE_ENABLED:
        return
    _load_cache()
    record = payload | {"ts": str(time.time())}
    _cache_store[key] = record
    _debug(f"cache set {key}")
    _save_cache()


@dataclass(slots=True)
class GeoPFFile:
    resource: str
    subresource: str
    filename: str
    updated: str
    url: str


def _fetch(url: str) -> bytes:
    req_id = next_req_id()
    req = urllib.request.Request(url, headers={"User-Agent": "geodock-index-builder"})
    delay = 0.5
    for attempt in range(5):
        _throttle()
        try:
            # Log le départ effectif (après throttle)
            http_log(f"#{req_id} GET", url)
            start = time.time()
            with urllib.request.urlopen(req, timeout=20) as resp:
                payload = resp.read()
                ms = (time.time() - start) * 1000.0
                http_log(f"#{req_id} 200", url, status=getattr(resp, 'status', '200'), bytes=len(payload), ms=f"{ms:.1f}")
                return payload
        except urllib.error.HTTPError as exc:  # pragma: no cover - réseau
            http_log(f"#{req_id} HTTP", url, status=exc.code)
            if exc.code in (429, 500, 502, 503, 504) and attempt < 4:
                if exc.code == 429 and _ABORT_ON_429:
                    raise RuntimeError("ABORT_ON_429: GeoPF returned 429") from exc
                retry_after = 0.0
                try:
                    retry_after = float(exc.headers.get("Retry-After", "0"))
                except Exception:  # pragma: no cover - conversion défensive
                    retry_after = 0.0
                wait = max(delay, retry_after)
                http_log(f"#{req_id} RETRY", url, wait_s=f"{wait:.1f}", attempt=f"{attempt + 1}/5")
                time.sleep(wait)
                delay *= 2
                continue
            raise
        except urllib.error.URLError as exc:  # pragma: no cover - réseau
            http_log(f"#{req_id} URLERR", url, error=str(exc))
            if attempt < 4:
                wait = max(delay, 1.0)
                http_log(f"#{req_id} RETRY", url, wait_s=f"{wait:.1f}", attempt=f"{attempt + 1}/5")
                time.sleep(wait)
                delay *= 2
                continue
            raise


def _head_ok(url: str) -> bool:
    req_id = next_req_id()
    req = urllib.request.Request(url, headers={"User-Agent": "geodock-index-builder"}, method="HEAD")
    try:
        _throttle()
        http_log(f"#{req_id} HEAD", url)
        start = time.time()
        with urllib.request.urlopen(req, timeout=20) as resp:
            ok = 200 <= resp.status < 400
            ms = (time.time() - start) * 1000.0
            http_log(f"#{req_id} HEAD_OK", url, status=resp.status, ok=ok, ms=f"{ms:.1f}")
            return ok
    except urllib.error.HTTPError as exc:  # pragma: no cover - dépend du réseau
        if getattr(exc, 'code', None) == 429 and _ABORT_ON_429:
            http_log(f"#{req_id} HEAD_ERR", url, error=str(exc))
            raise RuntimeError("ABORT_ON_429: GeoPF returned 429 (HEAD)") from exc
        http_log(f"#{req_id} HEAD_ERR", url, error=str(exc))
        return False
    except Exception as exc:  # pragma: no cover - dépend du réseau
        http_log(f"#{req_id} HEAD_ERR", url, error=str(exc))
        return False


def _latest_entry(feed_xml: bytes):
    root = ET.fromstring(feed_xml)
    entries: list[tuple[str, str, str]] = []
    for entry in root.findall("atom:entry", NS_ATOM):
        updated = entry.findtext("atom:updated", default="", namespaces=NS_ATOM)
        title = entry.findtext("atom:title", default="", namespaces=NS_ATOM)
        link_el = entry.find("atom:link", NS_ATOM)
        href = link_el.attrib.get("href") if link_el is not None else ""
        entries.append((updated or "", title or "", href or ""))
    entries.sort(key=lambda item: item[0], reverse=True)
    return entries[0] if entries else ("", "", "")


def _pagecount(feed_xml: bytes) -> int:
    root = ET.fromstring(feed_xml)
    for key, value in root.attrib.items():
        if key.endswith("pagecount"):
            try:
                return int(value)
            except Exception:  # pragma: no cover - conversion défensive
                return 1
    return 1


def _resource_feed(resource: str, page: int | None = None, **params) -> bytes:
    query = {k: v for k, v in params.items() if v}
    if page is not None:
        query["page"] = str(page)
    qs = urllib.parse.urlencode(query)
    suffix = f"?{qs}" if qs else ""
    url = f"{BASE}/resource/{resource}{suffix}"
    _debug(f"resource_feed resource={resource} page={page} params={query}")
    return _fetch(url)


def _files_feed(resource: str, subresource: str) -> bytes:
    url = f"{BASE}/resource/{resource}/{subresource}"
    _debug(f"files_feed resource={resource} subresource={subresource}")
    return _fetch(url)


def _download_url(resource: str, subresource: str, filename: str) -> str:
    url = f"{BASE}/download/resource/{resource}/{subresource}/{filename}"
    _debug(f"download_url {url}")
    return url


def _parse_date_from_title(title: str) -> str:
    parts = title.rsplit("_", 1)
    if len(parts) == 2 and len(parts[1]) == 10 and parts[1][4] == "-" and parts[1][7] == "-":
        return parts[1]
    return ""


def _iso_to_ts(value: str) -> float:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:  # pragma: no cover - conversion défensive
        return 0.0


def _choose_by_title(feed_xml: bytes, must_contain: Iterable[str], fallback: bool = False) -> tuple[str, str]:
    root = ET.fromstring(feed_xml)
    candidates: list[tuple[float, str, str, str]] = []
    total_entries = 0
    for entry in root.findall("atom:entry", NS_ATOM):
        title = entry.findtext("atom:title", default="", namespaces=NS_ATOM)
        updated = entry.findtext("atom:updated", default="", namespaces=NS_ATOM)
        link = ""
        total_entries += 1
        for link_el in entry.findall("atom:link", NS_ATOM):
            if link_el.attrib.get("rel") == "alternate":
                link = link_el.attrib.get("href", "")
                break
        if not title or not link:
            continue
        if all(fragment in title for fragment in must_contain):
            candidates.append((
                _iso_to_ts(updated or ""),
                _parse_date_from_title(title),
                title,
                link,
            ))
    _debug(f"choose_by_title fragments={list(must_contain)} total_entries={total_entries} matches={len(candidates)}")
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    if candidates:
        _debug(f"choose_by_title retenu={candidates[0][2]} url={candidates[0][3]}")
        return candidates[0][2], candidates[0][3]
    if fallback:
        updated, title, link = _latest_entry(feed_xml)
        _debug(f"choose_by_title fallback -> title={title} url={link}")
        return title, link
    _debug("choose_by_title aucun résultat")
    return "", ""


def dep_to_zone(dep: str) -> str:
    value = dep.strip().upper()
    if value in {"2A", "2B"}:
        return f"D{value}"
    if value.startswith("D") and value[1:].isdigit():
        return value
    if value.isdigit():
        return f"D{int(value):03d}"
    return f"D{value}"


def crs_label_for_bdtopo(crs: str) -> str:
    upper = crs.upper()
    if upper.endswith(":2154") or upper in {"EPSG:2154", "2154"}:
        return "LAMB93"
    if upper.endswith(":4326") or upper in {"EPSG:4326", "4326"}:
        return "WGS84G"
    return "LAMB93"


def resolve_admin(zone: str = "FRA", crs: str = "EPSG:4326") -> GeoPFFile:
    resource = "ADMIN-EXPRESS-COG"
    cache_key = _cache_key("admin", zone, crs)
    cached = _cache_get(cache_key)
    if cached:
        _log(f"[ADMIN {zone}] cache utilisé")
        return GeoPFFile(
            resource,
            cached["subresource"],
            cached["filename"],
            cached.get("updated", ""),
            cached["url"],
        )
    first_page = _resource_feed(resource)
    page_count = _pagecount(first_page)
    _log(f"[ADMIN] pages={page_count}")
    page_cache: dict[int, bytes] = {}
    if page_count <= 1:
        page_cache[1] = first_page

    def admin_feed(page: int) -> bytes:
        if page not in page_cache:
            page_cache[page] = _resource_feed(resource, page=page)
        return page_cache[page]

    title = link = ""
    max_pages = min(page_count, 10)
    for fragments in (["SHP", f"_{zone}_"], ["GPKG", f"_{zone}_"]):
        page = page_count
        tries = max_pages
        while page >= 1 and tries > 0:
            feed = admin_feed(page)
            _debug(f"[ADMIN] analyse page={page} fragments={fragments}")
            title, link = _choose_by_title(feed, fragments, fallback=False)
            if link:
                break
            page -= 1
            tries -= 1
        if link:
            break
    if not link:
        raise RuntimeError("Aucun lien trouvé pour ADMIN-EXPRESS-COG")
    subresource = link.rstrip("/").split("/")[-1]
    files = _files_feed(resource, subresource)
    root = ET.fromstring(files)
    href = ""
    for entry in root.findall("atom:entry", NS_ATOM):
        for link_el in entry.findall("atom:link", NS_ATOM):
            candidate = link_el.attrib.get("href", "")
            if candidate.endswith(".7z"):
                _debug(f"[ADMIN] candidat .7z={candidate}")
                if not _VERIFY_HEAD or _head_ok(candidate):
                    href = candidate
                    break
        if href:
            break
    if not href:
        raise RuntimeError("Aucun fichier .7z disponible pour ADMIN-EXPRESS-COG")
    filename = href.rstrip("/").split("/")[-1]
    _cache_put(
        cache_key,
        {
            "subresource": subresource,
            "filename": filename,
            "updated": _parse_date_from_title(title),
            "url": href,
        },
    )
    return GeoPFFile(resource, subresource, filename, _parse_date_from_title(title), href)


def resolve_bdtopo(dep: str, crs: str = "EPSG:2154") -> GeoPFFile:
    resource = "BDTOPO"
    zone = dep_to_zone(dep)
    crs_tag = crs_label_for_bdtopo(crs)
    cache_key = _cache_key("bdtopo", zone, crs_tag)
    cached = _cache_get(cache_key)
    if cached:
        _log(f"[BDTOPO {zone}] cache utilisé")
        return GeoPFFile(
            resource,
            cached["subresource"],
            cached["filename"],
            cached.get("updated", ""),
            cached["url"],
        )
    first_page = _resource_feed(resource, zone=zone)
    page_count = _pagecount(first_page)
    _log(f"[BDTOPO {zone}] pages={page_count}")
    page_cache: dict[int, bytes] = {page_count: first_page if page_count <= 1 else _resource_feed(resource, zone=zone, page=page_count)}

    def bdtopo_feed(page: int) -> bytes:
        if page not in page_cache:
            page_cache[page] = _resource_feed(resource, zone=zone, page=page)
        return page_cache[page]

    title = link = ""
    for fragments in (
        ["TOUSTHEMES", "GPKG", crs_tag, f"_{zone}_"],
        ["TOUSTHEMES", "SHP", crs_tag, f"_{zone}_"],
    ):
        page = page_count
        tries = 30
        while page >= 1 and tries > 0:
            feed = bdtopo_feed(page)
            _debug(f"[BDTOPO {zone}] analyse page={page} tries={tries} fragments={fragments}")
            title, link = _choose_by_title(feed, fragments, fallback=False)
            if link:
                break
            page -= 1
            tries -= 1
        if link:
            break
    if not link:
        raise RuntimeError("Aucun lien trouvé pour BDTOPO")
    subresource = link.rstrip("/").split("/")[-1]
    files = _files_feed(resource, subresource)
    root = ET.fromstring(files)
    href = ""
    for entry in root.findall("atom:entry", NS_ATOM):
        for link_el in entry.findall("atom:link", NS_ATOM):
            candidate = link_el.attrib.get("href", "")
            if candidate.endswith(".7z"):
                _debug(f"[BDTOPO {zone}] candidat .7z={candidate}")
                if not _VERIFY_HEAD or _head_ok(candidate):
                    href = candidate
                    break
        if href:
            break
    if not href:
        raise RuntimeError("Aucun fichier .7z disponible pour BDTOPO")
    filename = href.rstrip("/").split("/")[-1]
    _cache_put(
        cache_key,
        {
            "subresource": subresource,
            "filename": filename,
            "updated": _parse_date_from_title(title),
            "url": href,
        },
    )
    return GeoPFFile(resource, subresource, filename, _parse_date_from_title(title), href)


def resolve_parcellaire(dep: str, crs: str = "EPSG:2154") -> GeoPFFile:
    resource = "PARCELLAIRE-EXPRESS"
    zone = dep_to_zone(dep)
    cache_key = _cache_key("parcel", zone, crs)
    cached = _cache_get(cache_key)
    if cached:
        _log(f"[PARCEL {zone}] cache utilisé")
        return GeoPFFile(
            resource,
            cached["subresource"],
            cached["filename"],
            cached.get("updated", ""),
            cached["url"],
        )
    first_page = _resource_feed(resource, zone=zone)
    page_count = _pagecount(first_page)
    _log(f"[PARCEL {zone}] pages={page_count}")
    feed = first_page if page_count <= 1 else _resource_feed(resource, zone=zone, page=page_count)
    title, link = _choose_by_title(feed, ["SHP", f"_{zone}_"], fallback=False)
    page = page_count
    tries = 30
    while not link and page > 1 and tries > 0:
        page -= 1
        tries -= 1
        feed = _resource_feed(resource, zone=zone, page=page)
        _debug(f"[PARCEL {zone}] fallback page={page} tries={tries}")
        title, link = _choose_by_title(feed, ["SHP", f"_{zone}_"], fallback=False)
    if not link:
        raise RuntimeError("Aucun lien trouvé pour PARCELLAIRE-EXPRESS")
    subresource = link.rstrip("/").split("/")[-1]
    files = _files_feed(resource, subresource)
    root = ET.fromstring(files)
    href = ""
    for entry in root.findall("atom:entry", NS_ATOM):
        for link_el in entry.findall("atom:link", NS_ATOM):
            candidate = link_el.attrib.get("href", "")
            if candidate.endswith(".7z"):
                _debug(f"[PARCEL {zone}] candidat .7z={candidate}")
                if not _VERIFY_HEAD or _head_ok(candidate):
                    href = candidate
                    break
        if href:
            break
    if not href:
        raise RuntimeError("Aucun fichier .7z disponible pour PARCELLAIRE-EXPRESS")
    filename = href.rstrip("/").split("/")[-1]
    _cache_put(
        cache_key,
        {
            "subresource": subresource,
            "filename": filename,
            "updated": _parse_date_from_title(title),
            "url": href,
        },
    )
    return GeoPFFile(resource, subresource, filename, _parse_date_from_title(title), href)


def bdtopo_template(file: GeoPFFile, crs: str) -> str:
    zone = file.filename.split("_")[-2]
    template = file.url.replace(zone, "{dep}")
    template = template.replace(crs_label_for_bdtopo(crs), "{crs}")
    return template


def parcellaire_template(file: GeoPFFile, crs: str) -> str:
    parts = file.filename.split("_")
    template = file.url
    if len(parts) >= 5:
        template = template.replace(parts[-2], "{dep}")
        template = template.replace(parts[-3], "{crs}")
    return template


__all__ = [
    "GeoPFFile",
    "bdtopo_template",
    "crs_label_for_bdtopo",
    "dep_to_zone",
    "parcellaire_template",
    "resolve_admin",
    "resolve_bdtopo",
    "resolve_parcellaire",
]
