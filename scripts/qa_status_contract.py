#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any
from urllib.request import urlopen


STATES = {"preflight", "starting", "bootstrapping", "downloading", "building", "updating", "ready", "degraded", "error"}
MODES = {"proxy", "local", "hybrid", "failback", "remote"}
UPSTREAMS = {"remote", "local", "mixed", "unknown"}
COMPONENTS = {"address", "parcel", "poi", "api"}
SCOPES = {"departements", "france"}


def load_payload(args: argparse.Namespace) -> dict[str, Any]:
    if args.file:
        return json.loads(Path(args.file).read_text("utf-8"))
    with urlopen(args.url, timeout=args.timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url")
    parser.add_argument("--file")
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--expected-mode")
    parser.add_argument("--expected-state")
    parser.add_argument("--expected-upstream")
    parser.add_argument("--require-local-enabled", action="store_true")
    args = parser.parse_args()

    if not args.url and not args.file:
        raise SystemExit("Provide --url or --file")

    data = load_payload(args)
    ensure(isinstance(data, dict), "status payload must be an object")
    for key in [
        "state",
        "mode",
        "upstream_active",
        "local_enabled",
        "local_ready",
        "scope",
        "departements",
        "current_step",
        "progress",
        "started_at",
        "updated_at",
        "last_error",
        "last_successful_update_at",
    ]:
        ensure(key in data, f"missing key: {key}")

    ensure(data["state"] in STATES, f"invalid state: {data['state']}")
    ensure(data["mode"] in MODES, f"invalid mode: {data['mode']}")
    ensure(data["upstream_active"] in UPSTREAMS, f"invalid upstream_active: {data['upstream_active']}")
    ensure(data["scope"] in SCOPES, f"invalid scope: {data['scope']}")
    ensure(isinstance(data["local_enabled"], bool), "local_enabled must be boolean")
    ensure(isinstance(data["departements"], list), "departements must be a list")
    ensure(all(isinstance(item, str) for item in data["departements"]), "departements entries must be strings")
    ensure(isinstance(data["current_step"], str) and data["current_step"], "current_step must be a non-empty string")
    ensure(isinstance(data["progress"], dict), "progress must be an object")
    for key in ["current", "total", "percent"]:
        ensure(key in data["progress"], f"missing progress.{key}")
        ensure(isinstance(data["progress"][key], int), f"progress.{key} must be an integer")
    ensure(0 <= data["progress"]["percent"] <= 100, "progress.percent must be between 0 and 100")

    ready = data["local_ready"]
    ensure(isinstance(ready, dict), "local_ready must be an object")
    ensure(set(ready.keys()) == COMPONENTS, "local_ready must contain address, parcel, poi, api")
    for key in COMPONENTS:
        ensure(isinstance(ready[key], bool), f"local_ready.{key} must be boolean")
    ensure(data["last_error"] is None or isinstance(data["last_error"], str), "last_error must be null or a string")
    ensure(
        data["last_successful_update_at"] is None or isinstance(data["last_successful_update_at"], str),
        "last_successful_update_at must be null or a string",
    )

    if args.expected_mode:
        ensure(data["mode"] == args.expected_mode, f"expected mode={args.expected_mode}, got {data['mode']}")
    if args.expected_state:
        ensure(data["state"] == args.expected_state, f"expected state={args.expected_state}, got {data['state']}")
    if args.expected_upstream:
        ensure(
            data["upstream_active"] == args.expected_upstream,
            f"expected upstream_active={args.expected_upstream}, got {data['upstream_active']}",
        )
    if args.require_local_enabled:
        ensure(data["local_enabled"] is True, "local_enabled must be true")

    print(json.dumps({"ok": True, "mode": data["mode"], "state": data["state"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
