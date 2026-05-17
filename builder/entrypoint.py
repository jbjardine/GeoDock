#!/usr/bin/env python3
"""Point d'entrée du conteneur geodock-index-builder."""

from __future__ import annotations

import functools
import hashlib
import json
import os
import shutil
import tarfile
import subprocess
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from resolver import (
    bdtopo_template,
    parcellaire_template,
    resolve_admin,
    resolve_bdtopo,
    resolve_parcellaire,
    http_log,
    next_req_id,
    _throttle as _resolver_throttle,
)

# Boto3 is only required when S3 publication is enabled. Allow running locally
# (e.g., manifest-only flows) without the dependency present.
try:  # pragma: no cover - optional dependency handling
    import boto3  # type: ignore
    from botocore.config import Config as BotoConfig  # type: ignore
    from botocore.exceptions import BotoCoreError, ClientError  # type: ignore
    _HAS_BOTO3 = True
except Exception:  # pragma: no cover - optional dependency handling
    boto3 = None  # type: ignore
    BotoConfig = None  # type: ignore
    BotoCoreError = ClientError = Exception  # type: ignore
    _HAS_BOTO3 = False

DEFAULT_THEMES = ("address", "parcel", "poi")
_GEOPF_REQUEST_INTERVAL = float(os.getenv("GEOPF_REQUEST_INTERVAL", "1.5"))
_GEOPF_LAST_REQUEST = 0.0
_HEAD_CACHE_ENABLED = os.getenv("GEOPF_HEAD_CACHE", os.getenv("GEOPF_CACHE", "1")).lower() not in {"0", "false", "no"}
_HEAD_CACHE_PATH = Path(
    os.getenv(
        "GEOPF_HEAD_CACHE_PATH",
        str((Path.home() / ".cache" / "geodock" / "geopf-heads.json").resolve()),
    )
)
_HEAD_CACHE_TTL = max(0, int(os.getenv("GEOPF_HEAD_CACHE_TTL", os.getenv("GEOPF_CACHE_TTL", "86400"))))
_HEAD_CACHE: dict[str, dict[str, str]] = {}
_HEAD_CACHE_LOADED = False
_HEAD_MEM_CACHE: dict[str, tuple[str | None, str | None]] = {}
_ABORT_ON_429 = os.getenv("GEOPF_ABORT_ON_429", "0").lower() in {"1", "true", "yes"}
_NO_HEAD_GEO = os.getenv("GEO_FALLBACK_NO_HEAD", "0").lower() in {"1", "true", "yes"}


@dataclass(slots=True)
class Source:
    name: str
    url: str
    etag: str | None
    updated: str | None = None


@dataclass(slots=True)
class ThemeResult:
    theme: str
    archive_path: Path
    archive_url: str
    sha256: str
    indexed_at: str
    departements: list[str]
    crs: str | None
    sources: list[Source]


def _safe_unlink(path: Path) -> None:
    try:
        if path.exists() or path.is_symlink():
            path.unlink()
    except Exception:
        pass


def create_latest_alias(
    theme: str,
    archive_path: Path,
    output_dir: Path,
    publish_s3: bool,
    s3_uploaded_key: str | None,
    prefix: str,
) -> tuple[Path, str] | tuple[None, None]:
    """Create/update a stable "latest" alias for the given theme.

    - Locally: tries to create a symlink `index-<theme>-latest.tar.gz` next to the archive,
      falls back to a file copy if symlink fails (e.g. FS limitations).
    - S3 (optional): if enabled and boto3 is available, also writes a second object
      `<prefix>index-<theme>-latest.tar.gz` by copying the just-uploaded key.
    - Returns (alias_path, alias_url) or (None, None) if alias disabled.
    """
    enable_alias = getenv_bool("LATEST_ALIAS", True)
    if not enable_alias:
        return None, None

    alias_name = f"index-{theme}-latest.tar.gz"
    alias_path = output_dir / alias_name

    # Local alias: prefer copy by default (more portable on some FS),
    # allow symlink if explicitly requested.
    _safe_unlink(alias_path)
    prefer_symlink = getenv_bool("LATEST_ALIAS_SYMLINK", False)
    if prefer_symlink:
        try:
            os.symlink(archive_path.name, alias_path)  # relative symlink
        except Exception:
            try:
                shutil.copy2(archive_path, alias_path)
            except Exception:
                return None, None
    else:
        try:
            shutil.copy2(archive_path, alias_path)
        except Exception:
            try:
                os.symlink(archive_path.name, alias_path)
            except Exception:
                return None, None

    alias_url = final_url_for_local(alias_path)

    # Optional S3 alias creation via copy_object
    if publish_s3 and s3_uploaded_key and _HAS_BOTO3 and getenv_bool("S3_LATEST_ALIAS", True):
        try:
            bucket = getenv("S3_BUCKET")
            if bucket:
                s3_prefix = getenv("S3_PREFIX", "") or ""
                alias_key = f"{s3_prefix}{prefix}{alias_name}" if (prefix or s3_prefix) else alias_name
                alias_key = alias_key.lstrip("/")
                endpoint = getenv("S3_ENDPOINT")
                region = getenv("S3_REGION")
                boto_config = BotoConfig(signature_version="s3v4")
                session = boto3.session.Session()
                client = session.client("s3", endpoint_url=endpoint, region_name=region, config=boto_config)
                client.copy(
                    {"Bucket": bucket, "Key": s3_uploaded_key},
                    bucket,
                    alias_key,
                    ExtraArgs={"ContentType": "application/gzip"},
                )
                vhost = getenv("S3_VHOST")
                if vhost:
                    alias_url = f"https://{vhost.rstrip('/')}/{alias_key}"
                elif endpoint:
                    alias_url = f"{endpoint.rstrip('/')}/{bucket}/{alias_key}"
                else:
                    alias_url = f"s3://{bucket}/{alias_key}"
        except Exception as exc:
            log(f"Alias S3 ignoré (copy) : {exc}")

    return alias_path, alias_url


def enforce_retention(
    theme: str,
    output_dir: Path,
    retention_count: int,
    publish_s3: bool,
    prefix: str,
) -> None:
    """Keep only the last N timestamped archives per theme.

    - Never deletes the `index-<theme>-latest.tar.gz` alias.
    - S3 optional: if `RETENTION_APPLY_S3=1`, also prunes older objects under
      `<S3_PREFIX><prefix>index-<theme>-*` beyond the same count.
    """
    if retention_count <= 0:
        return
    pattern = f"index-{theme}-*.tar.gz"
    files = [p for p in output_dir.glob(pattern) if "-latest" not in p.name]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    to_delete = files[retention_count:]
    for old in to_delete:
        try:
            old.unlink()
        except Exception:
            pass

    if publish_s3 and _HAS_BOTO3 and getenv_bool("RETENTION_APPLY_S3", False):
        try:
            bucket = getenv("S3_BUCKET")
            if not bucket:
                return
            s3_prefix = getenv("S3_PREFIX", "") or ""
            base_prefix = f"{s3_prefix}{prefix}index-{theme}-"
            base_prefix = base_prefix.lstrip("/")
            endpoint = getenv("S3_ENDPOINT")
            region = getenv("S3_REGION")
            boto_config = BotoConfig(signature_version="s3v4")
            session = boto3.session.Session()
            client = session.client("s3", endpoint_url=endpoint, region_name=region, config=boto_config)
            # List all objects under base_prefix
            keys: list[dict] = []
            token = None
            while True:
                kwargs = {"Bucket": bucket, "Prefix": base_prefix}
                if token:
                    kwargs["ContinuationToken"] = token
                resp = client.list_objects_v2(**kwargs)
                for obj in resp.get("Contents", []) or []:
                    keys.append(obj)
                token = resp.get("NextContinuationToken")
                if not token:
                    break
            # Sort by LastModified desc, keep first retention_count
            keys.sort(key=lambda o: o.get("LastModified"), reverse=True)
            old_keys = [o["Key"] for o in keys[retention_count:]]
            if old_keys:
                # Batch delete (max 1000/key)
                batches = [old_keys[i : i + 1000] for i in range(0, len(old_keys), 1000)]
                for batch in batches:
                    client.delete_objects(Bucket=bucket, Delete={"Objects": [{"Key": k} for k in batch]})
        except Exception as exc:
            log(f"Rétention S3 ignorée : {exc}")


def log(message: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    print(f"[builder] {now} {message}")  # noqa: T201


def getenv(name: str, default: str | None = None) -> str | None:
    value = os.getenv(name)
    if value is not None:
        return value
    return default


def getenv_bool(name: str, default: bool = False) -> bool:
    value = getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "TRUE", "yes", "YES"}


def split_csv(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def ensure_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def _head_cache_load() -> None:
    global _HEAD_CACHE_LOADED
    if _HEAD_CACHE_LOADED or not _HEAD_CACHE_ENABLED:
        return
    try:
        if _HEAD_CACHE_PATH.exists():
            data = json.loads(_HEAD_CACHE_PATH.read_text("utf-8"))
            if isinstance(data, dict):
                _HEAD_CACHE.update({str(k): dict(v) for k, v in data.items() if isinstance(v, dict)})
    except Exception as exc:  # pragma: no cover - robustesse
        log(f"[cache] Lecture impossible ({exc})")
    _HEAD_CACHE_LOADED = True


def _head_cache_save() -> None:
    if not _HEAD_CACHE_ENABLED:
        return
    try:
        _HEAD_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        _HEAD_CACHE_PATH.write_text(json.dumps(_HEAD_CACHE, indent=2, ensure_ascii=False), "utf-8")
    except Exception as exc:  # pragma: no cover - robustesse
        log(f"[cache] Écriture impossible ({exc})")


def _head_cache_get(url: str) -> tuple[str | None, str | None] | None:
    if not _HEAD_CACHE_ENABLED:
        return None
    _head_cache_load()
    entry = _HEAD_CACHE.get(url)
    if not entry:
        return None
    ts = float(entry.get("ts", "0"))
    if _HEAD_CACHE_TTL and (time.time() - ts) > _HEAD_CACHE_TTL:
        return None
    return entry.get("etag") or None, entry.get("updated") or None


def _head_cache_put(url: str, etag: str | None, updated: str | None) -> None:
    if not _HEAD_CACHE_ENABLED:
        return
    _head_cache_load()
    _HEAD_CACHE[url] = {
        "etag": etag or "",
        "updated": updated or "",
        "ts": str(time.time()),
    }
    _head_cache_save()


def head_signature(url: str) -> tuple[str | None, str | None]:
    if not url:
        return None, None

    # Ne pas HEAD sur GeoPF si demandé (on s'appuie sur les listings .7z)
    try:
        from urllib.parse import urlparse
        if _NO_HEAD_GEO and 'data.geopf.fr' in urlparse(url).netloc:
            http_log("HEAD_SKIP(geopf)", url)
            return None, None
    except Exception:
        pass

    # In-process memoization to éviter des HEAD répétés durant un même run
    mem = _HEAD_MEM_CACHE.get(url)
    if mem:
        http_log("HEAD_CACHE(mem)", url, etag=mem[0] or "", updated=mem[1] or "")
        return mem

    cached = _head_cache_get(url)
    if cached:
        http_log("HEAD_CACHE", url, etag=cached[0] or "", updated=cached[1] or "")
        _HEAD_MEM_CACHE[url] = cached
        return cached

    attempt = 0
    backoff = max(_GEOPF_REQUEST_INTERVAL, 1.0)
    use_get = False
    headers: dict[str, str] = {}

    # Conditional headers si on possède déjà une trace, même expirée
    _head_cache_load()
    prior = _HEAD_CACHE.get(url)

    while True:
        method = "GET" if use_get else "HEAD"
        req_headers = {"User-Agent": "geodock-index-builder"}
        if use_get:
            req_headers["Range"] = "bytes=0-1"
        else:
            if prior:
                if prior.get("etag"):
                    req_headers["If-None-Match"] = prior["etag"]
                if prior.get("updated"):
                    req_headers["If-Modified-Since"] = prior["updated"]
        req = urllib.request.Request(url, method=method, headers=req_headers)

        try:
            req_id = next_req_id()
            _geopf_throttle()
            http_log(f"#{req_id} {method}", url)
            start = time.time()
            with urllib.request.urlopen(req, timeout=30) as response:
                status = getattr(response, 'status', 200)
                headers = {key.lower(): value for key, value in response.headers.items()}
                ms = (time.time() - start) * 1000.0
                http_log(f"#{req_id} {method}_OK", url, status=status, ms=f"{ms:.1f}")
            break
        except urllib.error.HTTPError as exc:
            if exc.code == 405 and not use_get:
                use_get = True
                continue
            if exc.code in (429, 500, 502, 503, 504) and attempt < 4:
                if exc.code == 429 and _ABORT_ON_429:
                    http_log("HEAD_HTTP", url, status=exc.code)
                    raise
                retry_after = 0.0
                try:
                    retry_after = float(exc.headers.get("Retry-After", "0"))
                except Exception:
                    retry_after = 0.0
                wait = max(backoff, retry_after, _GEOPF_REQUEST_INTERVAL)
                http_log("HEAD_RETRY", url, status=exc.code, wait_s=f"{wait:.1f}", attempt=f"{attempt+1}/5")
                time.sleep(wait)
                backoff = min(backoff * 2, 60.0)
                attempt += 1
                continue
            http_log("HEAD_HTTP", url, status=exc.code)
            raise
        except urllib.error.URLError as exc:
            if attempt < 4:
                wait = max(backoff, _GEOPF_REQUEST_INTERVAL)
                http_log("HEAD_URLERR", url, error=str(exc), wait_s=f"{wait:.1f}", attempt=f"{attempt+1}/5")
                time.sleep(wait)
                backoff = min(backoff * 2, 60.0)
                attempt += 1
                continue
            http_log("HEAD_URLERR", url, error=str(exc))
            raise

    etag = headers.get("etag")
    if etag:
        etag = etag.strip("\"")
    last_modified = headers.get("last-modified")
    _HEAD_MEM_CACHE[url] = (etag or None, last_modified or None)
    _head_cache_put(url, etag, last_modified)
    return etag or None, last_modified or None


def compute_signature(sources: Iterable[Source]) -> str:
    parts: list[str] = []
    for source in sources:
        parts.append(f"{source.name}:{source.etag or ''}:{source.updated or ''}:{source.url}")
    return "|".join(parts)


def load_state(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return {}


def save_state(path: Path, data: dict[str, str]) -> None:
    ensure_directory(path.parent)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
    tmp.replace(path)


def run_command(
    cmd: List[str],
    env: Optional[Dict[str, str]] = None,
    cwd: Path | None = None,
    retries: int = 0,
    retry_delay_sec: float = 0.0,
) -> None:
    attempt = 0
    while True:
        attempt += 1
        if retries > 0:
            log(f"Exécution ({attempt}/{retries + 1}) : {' '.join(cmd)}")
        else:
            log(f"Exécution : {' '.join(cmd)}")
        process_env = os.environ.copy()
        if env:
            process_env.update(env)
        proc = subprocess.run(cmd, env=process_env, cwd=str(cwd) if cwd else None, check=False)
        if proc.returncode == 0:
            return
        if attempt > retries:
            raise RuntimeError(f"Commande {' '.join(cmd)} terminée avec le code {proc.returncode}")
        delay = max(1.0, retry_delay_sec * attempt)
        log(
            f"Commande {' '.join(cmd)} en échec (code {proc.returncode}), "
            f"nouvelle tentative dans {delay:.0f}s"
        )
        time.sleep(delay)


def copy_archive(path: Path, output_dir: Path, prefix: str) -> Path:
    ensure_directory(output_dir)
    final_name = f"{prefix}{path.name}" if prefix else path.name
    dest = output_dir / final_name
    shutil.copy2(path, dest)
    return dest


def sha256sum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8192), b""):
            digest.update(chunk)
    return digest.hexdigest()


def upload_to_s3(path: Path, prefix: str) -> tuple[str, str]:
    bucket = getenv("S3_BUCKET")
    if not bucket:
        raise RuntimeError("S3_BUCKET doit être défini pour une publication S3")
    if not _HAS_BOTO3:
        raise RuntimeError(
            "Publication S3 demandée mais 'boto3' n'est pas installé dans cet environnement. "
            "Installez boto3 ou exécutez via l'image Docker fournie."
        )
    s3_prefix = getenv("S3_PREFIX", "")
    key = f"{s3_prefix}{prefix}{path.name}" if prefix or s3_prefix else path.name
    key = key.lstrip("/")
    endpoint = getenv("S3_ENDPOINT")
    region = getenv("S3_REGION")
    boto_config = BotoConfig(signature_version="s3v4")
    session = boto3.session.Session()
    client = session.client("s3", endpoint_url=endpoint, region_name=region, config=boto_config)
    extra_args: dict[str, str] = {}
    content_type = "application/gzip"
    extra_args["ContentType"] = content_type
    try:
        client.upload_file(str(path), bucket, key, ExtraArgs=extra_args)
    except (BotoCoreError, ClientError) as exc:
        raise RuntimeError(f"Échec de l'envoi S3 : {exc}") from exc
    vhost = getenv("S3_VHOST")
    if vhost:
        url = f"https://{vhost.rstrip('/')}/{key}"
    elif endpoint:
        url = f"{endpoint.rstrip('/')}/{bucket}/{key}"
    else:
        url = f"s3://{bucket}/{key}"
    return key, url


def resolve_address_sources() -> tuple[list[Source], dict[str, str], list[str], str | None]:
    template = getenv(
        "BAN_ADDOK_URL",
        "https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/adresses-addok-{dep}.ndjson.gz",
    )
    departments = split_csv(getenv("DEPARTEMENTS") or getenv("REFRESH_DEPARTEMENTS"))
    sample = departments[0] if departments else "75"
    url = template.replace("{dep}", sample)
    if getenv_bool("RESOLVE_SKIP_PROBE_HEAD", False):
        etag = last_modified = None
    else:
        etag, last_modified = head_signature(url)
    sources = [Source(name="BAN_ADDOK_URL", url=url, etag=etag, updated=last_modified)]
    env = {"BAN_ADDOK_URL": template}
    if departments:
        env["DEPARTEMENTS"] = ",".join(departments)
    return sources, env, departments, None


def resolve_parcel_sources() -> tuple[list[Source], dict[str, str], list[str], str | None]:
    departments = split_csv(getenv("DEPARTEMENTS") or getenv("REFRESH_DEPARTEMENTS"))
    dep = departments[0] if departments else "75"
    crs = getenv("PARCEL_CRS", "EPSG:2154")
    info = resolve_parcellaire(dep=dep, crs=crs)
    if getenv_bool("RESOLVE_SKIP_PROBE_HEAD", False):
        etag = last_modified = None
    else:
        etag, last_modified = head_signature(info.url)
    template = parcellaire_template(info, crs)
    env = {
        "PARCELLAIRE_EXPRESS_URL": template,
        "PARCEL_CRS": crs,
    }
    if departments:
        env["DEPARTEMENTS"] = ",".join(departments)
    sources = [Source(name="PARCELLAIRE_EXPRESS_URL", url=info.url, etag=etag, updated=info.updated or last_modified)]
    return sources, env, departments, crs


def resolve_poi_sources() -> tuple[list[Source], dict[str, str], list[str], str | None]:
    departments = split_csv(getenv("DEPARTEMENTS") or getenv("REFRESH_DEPARTEMENTS"))
    dep = departments[0] if departments else "75"
    admin_zone = getenv("ADMIN_ZONE", "FRA")
    admin_crs = getenv("ADMIN_CRS", "EPSG:4326")
    bdtopo_crs = getenv("BDTOPO_CRS", "EPSG:2154")
    admin = resolve_admin(zone=admin_zone, crs=admin_crs)
    bdtopo = resolve_bdtopo(dep=dep, crs=bdtopo_crs)
    if getenv_bool("RESOLVE_SKIP_PROBE_HEAD", False):
        etag_admin = lm_admin = None
        etag_bdtopo = lm_bdtopo = None
    else:
        etag_admin, lm_admin = head_signature(admin.url)
        etag_bdtopo, lm_bdtopo = head_signature(bdtopo.url)
    env = {
        "ADMIN_EXPRESS_URL": admin.url,
        "BDTOPO_URL": bdtopo_template(bdtopo, bdtopo_crs),
        "BDTOPO_CRS": bdtopo_crs,
    }
    if departments:
        env["DEPARTEMENTS"] = ",".join(departments)
    sources = [
        Source(name="ADMIN_EXPRESS_URL", url=admin.url, etag=etag_admin, updated=admin.updated or lm_admin),
        Source(name="BDTOPO_URL", url=bdtopo.url, etag=etag_bdtopo, updated=bdtopo.updated or lm_bdtopo),
    ]
    return sources, env, departments, bdtopo_crs


def prepare_theme(theme: str) -> tuple[list[Source], dict[str, str], list[str], str | None]:
    if theme == "address":
        return resolve_address_sources()
    if theme == "parcel":
        return resolve_parcel_sources()
    if theme == "poi":
        return resolve_poi_sources()
    raise ValueError(f"Thématique inconnue : {theme}")


def data_root() -> Path:
    value = getenv("DATA_PATH")
    if value:
        return Path(value).resolve()
    return Path("/data")


def tmp_root() -> Path:
    value = getenv("TMP_PATH")
    if value:
        return ensure_directory(Path(value).resolve())
    return ensure_directory(Path("/tmp"))


def index_path_for_theme(theme: str, root: Path) -> Path:
    theme_dir = root / theme / "index"
    if theme == "poi":
        theme_dir = root / "poi" / "index"
    return theme_dir


def pack_index(theme: str, root: Path, tmp_dir: Path) -> Path:
    index_dir = index_path_for_theme(theme, root)
    if not index_dir.exists():
        raise RuntimeError(f"Dossier index introuvable pour '{theme}' ({index_dir})")
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H-%M-%S")
    archive_name = f"index-{theme}-{timestamp}.tar.gz"
    archive_path = tmp_dir / archive_name
    with tarfile.open(archive_path, "w:gz") as tar:
        tar.add(index_dir, arcname=index_dir.name)
    return archive_path


def _geopf_throttle() -> None:
    # Délègue au throttle global du résolveur pour garantir 1 hit/s partagé
    _resolver_throttle()


def final_url_for_local(path: Path) -> str:
    base_url = getenv("CATALOG_BASE_URL")
    if base_url:
        return f"{base_url.rstrip('/')}/{path.name}"
    return path.resolve().as_uri()


def update_catalog(catalog_path: Path, result: ThemeResult) -> None:
    existing: dict = {}
    if catalog_path.exists():
        try:
            existing = json.loads(catalog_path.read_text("utf-8"))
        except Exception:
            existing = {}
    themes = existing.setdefault("themes", {})
    themes[result.theme] = {
        "indexed_at": result.indexed_at,
        "archive": {
            "path": str(result.archive_path),
            "url": result.archive_url,
            "sha256": result.sha256,
        },
        "departements": result.departements,
        "crs": result.crs,
        "sources": [
            {"name": source.name, "url": source.url, "etag": source.etag, "updated": source.updated}
            for source in result.sources
        ],
    }
    existing["generated_at"] = datetime.now(timezone.utc).isoformat()
    ensure_directory(catalog_path.parent)
    tmp = catalog_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(existing, indent=2, ensure_ascii=False), "utf-8")
    tmp.replace(catalog_path)


def serve_http(directory: Path) -> None:
    host = getenv("HTTP_HOST", "0.0.0.0") or "0.0.0.0"
    port_value = getenv("HTTP_PORT", "8000") or "8000"
    try:
        port = int(port_value)
    except ValueError as exc:
        raise ValueError(f"HTTP_PORT invalide : '{port_value}' n'est pas un entier") from exc
    handler = functools.partial(SimpleHTTPRequestHandler, directory=str(directory))
    try:
        with ThreadingHTTPServer((host, port), handler) as httpd:
            log(f"Serveur HTTP local prêt sur http://{host}:{port}/ (dossier {directory})")
            httpd.serve_forever()
    except OSError as exc:
        raise RuntimeError(f"Serveur HTTP local indisponible : {exc}") from exc


def main() -> None:
    geocodeur_path = Path(getenv("GEOCODEUR_PATH", "/opt/geocodeur") or "/opt/geocodeur")
    if not geocodeur_path.exists():
        raise RuntimeError(
            f"Répertoire Géocodeur introuvable : {geocodeur_path}. "
            "Montez le dépôt geodock/geocodeur dans le conteneur ou définissez GEOCODEUR_PATH."
        )
    output_dir = ensure_directory(Path(getenv("OUTPUT_DIR", "/out")))
    # For simple "user" runs, default DATA_PATH to /out/work so no extra mount is required.
    if not getenv("DATA_PATH"):
        os.environ["DATA_PATH"] = str(output_dir / "work")
    ensure_directory(Path(getenv("DATA_PATH", "/data")))
    state_path = Path(getenv("STATE_FILE", str(output_dir / "state.json")))
    catalog_path = Path(getenv("CATALOG_PATH", str(output_dir / "catalog.json")))
    prefix = getenv("INDEX_PREFIX", "") or ""
    themes_env = getenv("THEMES")
    if themes_env:
        themes = [item.strip() for item in themes_env.split(",") if item.strip()]
    else:
        themes = list(DEFAULT_THEMES)
    state = load_state(state_path)
    results: list[ThemeResult] = []
    force = getenv("FORCE_REBUILD", "0") in {"1", "true", "TRUE", "yes"}
    publish_s3 = bool(getenv("S3_BUCKET"))

    manifest_path = getenv("MANIFEST_PATH")
    precomputed_manifest: dict[str, Any] | None = None
    if manifest_path:
        manifest_file = Path(manifest_path)
        if manifest_file.exists():
            try:
                precomputed_manifest = json.loads(manifest_file.read_text("utf-8"))
                log(f"Manifest chargé depuis {manifest_file}")
            except Exception as exc:  # pragma: no cover - lecture défensive
                log(f"Impossible de lire le manifest {manifest_file}: {exc}")

    for theme in themes:
        manifest_theme = None
        if precomputed_manifest:
            manifest_theme = precomputed_manifest.get("themes", {}).get(theme)
        try:
            if manifest_theme:
                # Éviter toute résolution réseau si un manifest est fourni
                log(f"Manifest trouvé pour '{theme}': utilisation des URIs pré-calculées.")
                sources, env, departments, crs = [], {}, [], None
                manifest_sources_env = manifest_theme.get("env")
                if isinstance(manifest_sources_env, dict):
                    env.update({k: str(v) for k, v in manifest_sources_env.items()})
                manifest_deps = manifest_theme.get("departements")
                if isinstance(manifest_deps, list):
                    departments = [str(dep) for dep in manifest_deps]
            else:
                sources, env, departments, crs = prepare_theme(theme)
        except Exception as exc:
            log(f"Résolution des sources impossible pour '{theme}': {exc}")
            if getenv("STRICT", "0") in {"1", "true", "TRUE", "yes"}:
                raise
            else:
                continue
        if manifest_theme:
            manifest_sources = manifest_theme.get("sources")
            if isinstance(manifest_sources, list):
                override_sources: list[Source] = []
                for entry in manifest_sources:
                    if not isinstance(entry, dict):
                        continue
                    current = entry.get("current") if isinstance(entry.get("current"), dict) else entry
                    url = entry.get("local_url") or current.get("local_url") or entry.get("url") or current.get("url")
                    if not url:
                        continue
                    override_sources.append(
                        Source(
                            name=entry.get("kind") or "manifest",
                            url=entry.get("local_url") or url,
                            etag=entry.get("etag") or current.get("etag"),
                            updated=entry.get("updated") or current.get("updated"),
                        )
                    )
                if override_sources:
                    sources = override_sources
                    # Si le manifest fournit des local_url en file:// pour address,
                    # forcer BAN_ADDOK_URL vers le cache local afin que Yarn consomme les fichiers du cache.
                    if theme == "address" and any(s.url.startswith("file://") for s in sources):
                        # Align local cache path with the effective output directory.
                        base_mount = env.get("OUTPUT_DIR") or str(output_dir)
                        if not base_mount:
                            base_mount = "/out"
                        env["BAN_ADDOK_URL"] = f"file://{base_mount.rstrip('/')}/cache/address/{{dep}}/adresses-addok-{{dep}}.ndjson.gz"
        signature = compute_signature(sources)
        if not force and state.get(theme) == signature:
            log(f"Thématique '{theme}' à jour (signature {signature}).")
            continue
        log(f"Thématique '{theme}' : reconstruction nécessaire (signature {signature}).")
        try:
            # Ensure redis-py does not try to use hiredis (known incompatibility
            # with some versions in our stack); harmless for non-address builds.
            env = dict(env)
            env.setdefault("REDIS_DISABLE_HIREDIS", "1")
            build_retries = max(0, int(getenv("BUILD_INDEX_RETRY_COUNT", "1") or "1"))
            build_retry_delay = max(1.0, float(getenv("BUILD_INDEX_RETRY_DELAY_SEC", "30") or "30"))
            if theme == "poi":
                run_command(
                    ["yarn", "poi:build-from-bdtopo"],
                    env,
                    cwd=geocodeur_path,
                    retries=build_retries,
                    retry_delay_sec=build_retry_delay,
                )
            run_command(
                ["yarn", f"{theme}:build-index"],
                env,
                cwd=geocodeur_path,
                retries=build_retries,
                retry_delay_sec=build_retry_delay,
            )
        except Exception as exc:
            log(f"Erreur pendant la génération '{theme}': {exc}")
            if getenv("STRICT", "0") in {"1", "true", "TRUE", "yes"}:
                raise
            else:
                continue
        data_path_root = Path(env.get("DATA_PATH") or getenv("DATA_PATH", "/data")).resolve()
        tmp_dir = tmp_root()
        try:
            archive_source = pack_index(theme, data_path_root, tmp_dir)
        except Exception as exc:
            log(f"Packaging impossible pour '{theme}': {exc}")
            if getenv("STRICT", "0") in {"1", "true", "TRUE", "yes"}:
                raise
            else:
                continue
        copied = copy_archive(archive_source, output_dir, prefix)
        digest = sha256sum(copied)
        archive_url = final_url_for_local(copied)
        try:
            archive_source.unlink()
        except Exception:
            pass
        s3_key_uploaded: str | None = None
        if publish_s3:
            try:
                s3_key_uploaded, archive_url = upload_to_s3(copied, prefix)
            except Exception as exc:
                log(f"Publication S3 échouée : {exc}")
                if getenv("STRICT", "0") in {"1", "true", "TRUE", "yes"}:
                    raise
        indexed_at = datetime.now(timezone.utc).isoformat()
        result = ThemeResult(
            theme=theme,
            archive_path=copied,
            archive_url=archive_url,
            sha256=digest,
            indexed_at=indexed_at,
            departements=departments,
            crs=crs,
            sources=sources,
        )
        update_catalog(catalog_path, result)
        # Créer/mettre à jour l'alias "latest" et appliquer la rétention
        alias_path, alias_url = create_latest_alias(
            theme, copied, output_dir, publish_s3, s3_key_uploaded, prefix
        )
        if alias_path and alias_url:
            try:
                # Mettre à jour le catalog avec le champ "latest"
                existing: dict = {}
                if catalog_path.exists():
                    existing = json.loads(catalog_path.read_text("utf-8"))
                if isinstance(existing, dict):
                    themes_obj = existing.setdefault("themes", {})
                    theme_obj = themes_obj.setdefault(theme, {})
                    theme_obj["latest"] = {"path": str(alias_path), "url": alias_url}
                    tmp = catalog_path.with_suffix(".tmp")
                    tmp.write_text(json.dumps(existing, indent=2, ensure_ascii=False), "utf-8")
                    tmp.replace(catalog_path)
            except Exception as exc:
                log(f"Catalog.latest ignoré: {exc}")
        # Rétention locale (et éventuellement S3)
        retention = int(getenv("RETENTION_COUNT", "3") or "3")
        try:
            enforce_retention(theme, output_dir, retention, publish_s3, prefix)
        except Exception as exc:
            log(f"Rétention ignorée: {exc}")
        state[theme] = signature
        results.append(result)
        log(f"Thématique '{theme}' publiée : {copied}")

    save_state(state_path, state)
    if not results:
        log("Aucune reconstruction nécessaire.")
    else:
        log(f"{len(results)} thématique(s) mise(s) à jour.")

    if getenv_bool("SERVE_HTTP"):
        log("SERVE_HTTP actif : démarrage du serveur HTTP local.")
        serve_http(output_dir)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # pragma: no cover - log final
        log(f"Erreur fatale : {exc}")
        sys.exit(1)
