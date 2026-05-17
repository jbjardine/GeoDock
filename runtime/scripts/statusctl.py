#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import socket
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATUS_PATH = Path(os.getenv("GEODOCK_STATUS_FILE", os.getenv("GEODOCK_META_DIR", "/meta") + "/status.json"))
LOCK_PATH = STATUS_PATH.with_suffix(".lock")
DEFAULT_COMPONENTS = ("address", "parcel", "poi", "api")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def default_status() -> dict[str, Any]:
    return {
        "state": "preflight",
        "mode": "proxy",
        "upstream_active": "remote",
        "local_enabled": False,
        "local_ready": {name: False for name in DEFAULT_COMPONENTS},
        "scope": "departements",
        "departements": [],
        "current_step": "initialisation",
        "progress": {"current": 0, "total": 0, "percent": 0},
        "started_at": now_iso(),
        "updated_at": now_iso(),
        "last_error": None,
        "last_successful_update_at": None,
    }


def load_status() -> dict[str, Any]:
    if not STATUS_PATH.exists():
        return default_status()
    try:
        return json.loads(STATUS_PATH.read_text("utf-8"))
    except Exception:
        return default_status()


@contextmanager
def status_lock(timeout: float = 30.0):
    ensure_parent(LOCK_PATH)
    deadline = time.time() + timeout
    fd: int | None = None
    while True:
        try:
            fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_RDWR)
            break
        except FileExistsError:
            if time.time() >= deadline:
                raise TimeoutError(f"Impossible de verrouiller {LOCK_PATH}")
            time.sleep(0.1)
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)
        try:
            LOCK_PATH.unlink()
        except FileNotFoundError:
            pass


def derive_upstream(mode: str, api_ready: bool) -> str:
    if mode in {"proxy", "remote"}:
        return "remote"
    if mode == "local":
        return "local" if api_ready else "unknown"
    if mode == "hybrid":
        return "local" if api_ready else "remote"
    if mode == "failback":
        return "remote"
    return "unknown"


def normalize_progress(status: dict[str, Any]) -> None:
    progress = status.setdefault("progress", {})
    current = int(progress.get("current", 0) or 0)
    total = int(progress.get("total", 0) or 0)
    percent = 0 if total <= 0 else max(0, min(100, round(current * 100 / total)))
    progress["current"] = current
    progress["total"] = total
    progress["percent"] = percent


def finalize_status(status: dict[str, Any]) -> dict[str, Any]:
    ready = status.setdefault("local_ready", {name: False for name in DEFAULT_COMPONENTS})
    api_ready = bool(ready.get("api"))
    mode = str(status.get("mode") or "proxy")
    status["upstream_active"] = derive_upstream(mode, api_ready)
    if status.get("local_enabled"):
        if all(bool(ready.get(name)) for name in DEFAULT_COMPONENTS) and status.get("state") not in {"error", "degraded"}:
            status["state"] = "ready"
            status["current_step"] = "GeoDock est pret"
            if not status.get("last_successful_update_at"):
                status["last_successful_update_at"] = now_iso()
    else:
        if status.get("state") not in {"error", "degraded"}:
            status["state"] = "ready"
            status["current_step"] = "Proxy pret"
    normalize_progress(status)
    status["updated_at"] = now_iso()
    return status


def save_status(status: dict[str, Any]) -> None:
    ensure_parent(STATUS_PATH)
    tmp_path = STATUS_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(finalize_status(status), indent=2, ensure_ascii=False), "utf-8")
    tmp_path.chmod(0o644)
    tmp_path.replace(STATUS_PATH)
    STATUS_PATH.chmod(0o644)


def mutate_status(mutator) -> dict[str, Any]:
    with status_lock():
        status = load_status()
        mutator(status)
        save_status(status)
        return status


def init_status(mode: str, scope: str, departements: list[str], local_enabled: bool, current_step: str) -> None:
    def apply(status: dict[str, Any]) -> None:
        status.clear()
        status.update(default_status())
        status["mode"] = mode
        status["scope"] = scope
        status["departements"] = departements
        status["local_enabled"] = local_enabled
        status["current_step"] = current_step
        status["state"] = "starting" if local_enabled else "ready"

    mutate_status(apply)


def set_component(component: str, ready_value: bool) -> None:
    def apply(status: dict[str, Any]) -> None:
        ready = status.setdefault("local_ready", {name: False for name in DEFAULT_COMPONENTS})
        ready[component] = ready_value
        if ready_value and component == "api":
            status["last_successful_update_at"] = now_iso()

    mutate_status(apply)


def update_status(args: argparse.Namespace) -> None:
    def apply(status: dict[str, Any]) -> None:
        if args.state is not None:
            status["state"] = args.state
        if args.current_step is not None:
            status["current_step"] = args.current_step
        if args.mode is not None:
            status["mode"] = args.mode
        if args.scope is not None:
            status["scope"] = args.scope
        if args.departements is not None:
            status["departements"] = [item for item in args.departements.split(",") if item]
        if args.upstream_active is not None:
            status["upstream_active"] = args.upstream_active
        if args.local_enabled is not None:
            status["local_enabled"] = args.local_enabled == "true"
        if args.progress_current is not None:
            status.setdefault("progress", {})["current"] = args.progress_current
        if args.progress_total is not None:
            status.setdefault("progress", {})["total"] = args.progress_total
        if args.last_error is not None:
            status["last_error"] = args.last_error
        if args.clear_error:
            status["last_error"] = None
        if args.mark_success:
            status["last_successful_update_at"] = now_iso()

    mutate_status(apply)


def watch_port(component: str, host: str, port: int, timeout: int) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(1.5)
            if sock.connect_ex((host, port)) == 0:
                set_component(component, True)
                return 0
        time.sleep(1)
    status = load_status()
    status["state"] = "error"
    status["last_error"] = f"Le composant {component} n'a pas ouvert le port {port} a temps"
    save_status(status)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    init_cmd = sub.add_parser("init")
    init_cmd.add_argument("--mode", required=True)
    init_cmd.add_argument("--scope", required=True)
    init_cmd.add_argument("--departements", default="")
    init_cmd.add_argument("--local-enabled", action="store_true")
    init_cmd.add_argument("--current-step", default="initialisation")

    update_cmd = sub.add_parser("update")
    update_cmd.add_argument("--state")
    update_cmd.add_argument("--current-step")
    update_cmd.add_argument("--mode")
    update_cmd.add_argument("--scope")
    update_cmd.add_argument("--departements")
    update_cmd.add_argument("--upstream-active")
    update_cmd.add_argument("--last-error")
    update_cmd.add_argument("--clear-error", action="store_true")
    update_cmd.add_argument("--local-enabled", choices=["true", "false"])
    update_cmd.add_argument("--progress-current", type=int)
    update_cmd.add_argument("--progress-total", type=int)
    update_cmd.add_argument("--mark-success", action="store_true")

    comp_cmd = sub.add_parser("component")
    comp_cmd.add_argument("--name", required=True, choices=DEFAULT_COMPONENTS)
    comp_cmd.add_argument("--ready", choices=["true", "false"], required=True)

    watch_cmd = sub.add_parser("watch-port")
    watch_cmd.add_argument("--component", required=True, choices=DEFAULT_COMPONENTS)
    watch_cmd.add_argument("--host", default="127.0.0.1")
    watch_cmd.add_argument("--port", type=int, required=True)
    watch_cmd.add_argument("--timeout", type=int, default=1800)

    sub.add_parser("print")

    args = parser.parse_args()
    if args.cmd == "init":
        init_status(
            mode=args.mode,
            scope=args.scope,
            departements=[item for item in args.departements.split(",") if item],
            local_enabled=args.local_enabled,
            current_step=args.current_step,
        )
        return 0
    if args.cmd == "update":
        update_status(args)
        return 0
    if args.cmd == "component":
        set_component(args.name, args.ready == "true")
        return 0
    if args.cmd == "watch-port":
        return watch_port(args.component, args.host, args.port, args.timeout)
    print(json.dumps(load_status(), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
