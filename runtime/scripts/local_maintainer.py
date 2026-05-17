#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from statusctl import init_status, mutate_status


FRANCE_DEPARTEMENTS = [
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
THEMES = ("address", "parcel", "poi")
DATA_PATH = Path(os.getenv("DATA_PATH", "/data"))
OUTPUT_DIR = Path(os.getenv("OUTPUT_DIR", "/artifacts"))
META_DIR = Path(os.getenv("GEODOCK_META_DIR", "/meta"))
MODE = os.getenv("MODE", "hybrid")
LOCAL_SOURCE = os.getenv("LOCAL_SOURCE", "build")
LOCAL_SCOPE = os.getenv("LOCAL_SCOPE", "departements")
LOCAL_DEPARTEMENTS = [item.strip().upper() for item in os.getenv("LOCAL_DEPARTEMENTS", "").split(",") if item.strip()]
PROJECT_NAME = os.getenv("COMPOSE_PROJECT_NAME", "geodock")


def log(message: str) -> None:
    print(f"[local_maintainer] {datetime.now(timezone.utc).isoformat()} {message}", flush=True)  # noqa: T201


def departments() -> list[str]:
    if LOCAL_SCOPE == "france":
        return FRANCE_DEPARTEMENTS
    return LOCAL_DEPARTEMENTS


def sentinel_for(theme: str) -> Path:
    return DATA_PATH / theme / "index" / f"{theme}.mdb"


def update_status(state: str, step: str, current: int = 0, total: int = 0, last_error: str | None = None) -> None:
    def apply(status: dict) -> None:
        status["state"] = state
        status["current_step"] = step
        status.setdefault("progress", {})
        status["progress"]["current"] = current
        status["progress"]["total"] = total
        status["last_error"] = last_error

    mutate_status(apply)


def run(cmd: list[str], extra_env: dict[str, str] | None = None) -> None:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    log("run: " + " ".join(cmd))
    proc = subprocess.run(cmd, env=env, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"Commande echouee ({proc.returncode}): {' '.join(cmd)}")


def run_with_status_heartbeat(
    cmd: list[str],
    state: str,
    step: str,
    current: int,
    total: int,
    extra_env: dict[str, str] | None = None,
    heartbeat_sec: int = 60,
) -> None:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    log("run: " + " ".join(cmd))
    started = time.monotonic()
    proc = subprocess.Popen(cmd, env=env)
    heartbeat_idx = 0
    while True:
        try:
          returncode = proc.wait(timeout=heartbeat_sec)
          if returncode != 0:
              raise RuntimeError(f"Commande echouee ({returncode}): {' '.join(cmd)}")
          return
        except subprocess.TimeoutExpired:
          heartbeat_idx += 1
          elapsed_min = max(1, int((time.monotonic() - started) // 60))
          suffix = f" - heartbeat {heartbeat_idx} ({elapsed_min} min)"
          update_status(state, f"{step}{suffix}", current, total)


def ensure_manifest_seed() -> None:
    manifest_path = OUTPUT_DIR / "sources-manifest.json"
    old_path = OUTPUT_DIR / "sources-manifest.old.json"
    env = {
        "MANIFEST_PATH": str(manifest_path),
        "REFRESH_DEPARTEMENTS": ",".join(departments()),
    }
    run([sys.executable, "/opt/geodock-builder/manifest.py"], env)
    shutil.copy2(manifest_path, old_path)


def build_theme(theme: str, current: int, total: int, force_rebuild: bool) -> None:
    update_status("building", f"Build {theme}", current, total)
    env = {
        "THEMES": theme,
        "DEPARTEMENTS": ",".join(departments()),
        "OUTPUT_DIR": str(OUTPUT_DIR),
        "DATA_PATH": str(DATA_PATH),
        "STATE_FILE": str(OUTPUT_DIR / "state.json"),
        "CATALOG_PATH": str(OUTPUT_DIR / "catalog.json"),
        "FORCE_REBUILD": "1" if force_rebuild else "0",
        "LATEST_ALIAS": "1",
        "STRICT": "1",
        "POI_ADDOK_CLUSTER_NUM_NODES": os.getenv("POI_ADDOK_CLUSTER_NUM_NODES", "1"),
    }
    run_with_status_heartbeat(
        [sys.executable, "/opt/geodock-builder/entrypoint.py"],
        "building",
        f"Build {theme}",
        current,
        total,
        env,
    )


def bootstrap() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    META_DIR.mkdir(parents=True, exist_ok=True)
    if not (META_DIR / "status.json").exists():
        init_status(MODE, LOCAL_SCOPE, departments(), True, "Initialisation du bootstrap local")
    if LOCAL_SOURCE == "archive":
        update_status("downloading", "Le runtime local telechargera ses archives au demarrage", 0, 3)
        return

    missing = [theme for theme in THEMES if not sentinel_for(theme).exists()]
    if not missing:
        update_status("starting", "Index locaux deja presents, activation du runtime local", len(THEMES), len(THEMES))
        if not (OUTPUT_DIR / "sources-manifest.old.json").exists():
            ensure_manifest_seed()
        return

    for idx, theme in enumerate(missing, start=1):
        build_theme(theme, idx, len(missing), True)
    ensure_manifest_seed()
    update_status("starting", "Index locaux prets, activation du runtime local", len(THEMES), len(THEMES))


def read_manifest(path: Path) -> dict:
    return json.loads(path.read_text("utf-8"))


def collect_changed_themes(old_path: Path, new_path: Path) -> list[str]:
    old_manifest = read_manifest(old_path)
    new_manifest = read_manifest(new_path)
    changed: list[str] = []
    for theme in THEMES:
        old_theme = old_manifest.get("themes", {}).get(theme, {})
        new_theme = new_manifest.get("themes", {}).get(theme, {})
        if old_theme.get("signature") != new_theme.get("signature"):
            changed.append(theme)
    return changed


def restart_service(service: str) -> None:
    cmd = [
        "docker",
        "ps",
        "-q",
        "--filter",
        f"label=com.docker.compose.project={PROJECT_NAME}",
        "--filter",
        f"label=com.docker.compose.service={service}",
    ]
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    for container_id in [item.strip() for item in proc.stdout.splitlines() if item.strip()]:
        run(["docker", "restart", container_id])


def refresh_once() -> None:
    if LOCAL_SOURCE != "build":
        update_status("ready", "Mode archive: aucun rebuild local a lancer", 0, 0)
        return

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest_path = OUTPUT_DIR / "sources-manifest.json"
    old_path = OUTPUT_DIR / "sources-manifest.old.json"
    if manifest_path.exists():
        shutil.copy2(manifest_path, old_path)

    update_status("updating", "Analyse des sources amont", 0, len(THEMES))
    env = {
        "MANIFEST_PATH": str(manifest_path),
        "REFRESH_DEPARTEMENTS": ",".join(departments()),
    }
    run([sys.executable, "/opt/geodock-builder/manifest.py"], env)

    if not old_path.exists():
        shutil.copy2(manifest_path, old_path)
        update_status("ready", "Baseline de refresh initialisee", 0, 0)
        return

    changed = [theme for theme in collect_changed_themes(old_path, manifest_path) if theme in THEMES]
    changed.extend([theme for theme in THEMES if not sentinel_for(theme).exists() and theme not in changed])
    if not changed:
        shutil.copy2(manifest_path, old_path)
        update_status("ready", "Aucun rebuild necessaire", 0, 0)
        return

    for idx, theme in enumerate(changed, start=1):
        build_theme(theme, idx, len(changed), True)

    shutil.copy2(manifest_path, old_path)
    for service in [f"geocoder-{theme}" for theme in changed] + ["geocoder-api"]:
        restart_service(service)
    update_status("ready", f"Mise a jour appliquee: {', '.join(changed)}", len(changed), len(changed))


def parse_field(field: str, minimum: int, maximum: int) -> set[int]:
    values: set[int] = set()
    if field == "*":
        return set(range(minimum, maximum + 1))
    for part in field.split(","):
        if "/" in part:
            base, step_value = part.split("/", 1)
            step = int(step_value)
            start = minimum if base == "*" else int(base)
            values.update(range(start, maximum + 1, step))
        else:
            values.add(int(part))
    return {value for value in values if minimum <= value <= maximum}


def cron_matches(candidate: datetime, expression: str) -> bool:
    fields = expression.split()
    if len(fields) != 5:
        raise ValueError(f"Cron invalide: {expression}")
    minutes = parse_field(fields[0], 0, 59)
    hours = parse_field(fields[1], 0, 23)
    month_days = parse_field(fields[2], 1, 31)
    months = parse_field(fields[3], 1, 12)
    weekdays = parse_field(fields[4], 0, 7)
    cron_weekday = (candidate.weekday() + 1) % 7
    return (
        candidate.minute in minutes
        and candidate.hour in hours
        and candidate.day in month_days
        and candidate.month in months
        and (cron_weekday in weekdays or (cron_weekday == 0 and 7 in weekdays))
    )


def next_run(expression: str) -> datetime:
    candidate = datetime.now().astimezone().replace(second=0, microsecond=0) + timedelta(minutes=1)
    for _ in range(366 * 24 * 60):
        if cron_matches(candidate, expression):
            return candidate
        candidate += timedelta(minutes=1)
    raise RuntimeError(f"Impossible de calculer la prochaine execution pour {expression}")


def refresh_loop() -> None:
    auto_update = os.getenv("LOCAL_AUTO_UPDATE", "true").lower() in {"1", "true", "yes"}
    schedule = os.getenv("LOCAL_UPDATE_SCHEDULE_CRON", "0 3 * * 1")
    if not auto_update:
        log("LOCAL_AUTO_UPDATE=false, maintien du service en veille.")
        while True:
            time.sleep(3600)

    while True:
        next_at = next_run(schedule)
        wait_seconds = max(0, int((next_at - datetime.now().astimezone()).total_seconds()))
        log(f"Prochaine mise a jour locale planifiee a {next_at.isoformat()} ({wait_seconds}s)")
        while wait_seconds > 0:
            time.sleep(min(wait_seconds, 60))
            wait_seconds = max(0, int((next_at - datetime.now().astimezone()).total_seconds()))
        try:
            refresh_once()
        except Exception as exc:
            update_status("error", "La mise a jour locale a echoue", 0, 0, str(exc))
            log(f"Erreur de refresh: {exc}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["bootstrap", "refresh-once", "refresh-loop"])
    args = parser.parse_args()
    try:
        if args.action == "bootstrap":
            bootstrap()
        elif args.action == "refresh-once":
            refresh_once()
        else:
            refresh_loop()
    except Exception as exc:
        update_status("error", "Erreur pendant l'orchestration locale", 0, 0, str(exc))
        log(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
