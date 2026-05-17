#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "builder"))
sys.path.insert(0, str(ROOT / "runtime" / "scripts"))

import entrypoint  # noqa: E402
import statusctl  # noqa: E402


def assert_true(value: bool, message: str) -> None:
    if not value:
        raise AssertionError(message)


def test_status_keeps_refresh_state_after_local_ready() -> None:
    status = statusctl.default_status()
    status["local_enabled"] = True
    status["state"] = "updating"
    status["current_step"] = "Analyse des sources amont"
    status["local_ready"] = {name: True for name in statusctl.DEFAULT_COMPONENTS}

    finalized = statusctl.finalize_status(status)

    assert_true(finalized["state"] == "updating", "refresh state must not be hidden as ready")
    assert_true(finalized["current_step"] == "Analyse des sources amont", "refresh step must remain visible")


def test_status_reaches_ready_after_initial_local_start() -> None:
    status = statusctl.default_status()
    status["local_enabled"] = True
    status["state"] = "starting"
    status["local_ready"] = {name: True for name in statusctl.DEFAULT_COMPONENTS}

    finalized = statusctl.finalize_status(status)

    assert_true(finalized["state"] == "ready", "initial local startup must still become ready")


def test_manifest_error_blocks_rebuild() -> None:
    theme_error = entrypoint.manifest_entry_error("parcel", {"error": "resolver failed"})
    source_error = entrypoint.manifest_entry_error(
        "poi",
        {"sources": [{"kind": "bdtopo", "departement": "92", "error": "HEAD failed"}]},
    )

    assert_true(theme_error is not None and "parcel" in theme_error, "theme-level manifest errors must fail fast")
    assert_true(source_error is not None and "poi/bdtopo/92" in source_error, "source-level manifest errors must fail fast")


if __name__ == "__main__":
    test_status_keeps_refresh_state_after_local_ready()
    test_status_reaches_ready_after_initial_local_start()
    test_manifest_error_blocks_rebuild()
    print("ok - public release regression contracts")
