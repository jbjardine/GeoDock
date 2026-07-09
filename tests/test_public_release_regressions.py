#!/usr/bin/env python3
from __future__ import annotations

import re
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


def test_runtime_upstream_ref_is_immutable() -> None:
    dockerfile = (ROOT / "runtime" / "Dockerfile.gpf-geocodeur").read_text()
    compose = (ROOT / "docker-compose.git.yml").read_text()
    environment = (ROOT / ".env.example").read_text()
    dockerfile_match = re.search(r"^ARG GEOCODER_GIT_REF=([0-9a-f]{40})$", dockerfile, re.MULTILINE)
    compose_match = re.search(r"GEOCODER_GIT_REF:-([0-9a-f]{40})", compose)
    environment_match = re.search(r"^GEOCODER_GIT_REF=([0-9a-f]{40})$", environment, re.MULTILINE)

    assert_true(
        all((dockerfile_match, compose_match, environment_match)),
        "GHCR and fallback runtime builds must pin the upstream geocoder to immutable commits",
    )
    refs = {match.group(1) for match in (dockerfile_match, compose_match, environment_match) if match}
    assert_true(len(refs) == 1, "GHCR and fallback runtime builds must use the same upstream commit")
    assert_true(
        'fetch --depth 1 origin "${GEOCODER_GIT_REF}"' in dockerfile,
        "the runtime checkout must support the pinned upstream commit",
    )


def test_release_notes_do_not_repeat_first_release_copy() -> None:
    workflow = (ROOT / ".github" / "workflows" / "proxy-ci.yml").read_text()

    assert_true(
        "First stable public release" not in workflow,
        "later releases must not be mislabeled as the first stable release",
    )


def test_release_package_contains_changelog() -> None:
    release_script = (ROOT / "scripts" / "release_v2.sh").read_text()

    assert_true(
        "README.md CHANGELOG.md LICENSE" in release_script,
        "the published release archive must include its changelog",
    )


if __name__ == "__main__":
    test_status_keeps_refresh_state_after_local_ready()
    test_status_reaches_ready_after_initial_local_start()
    test_manifest_error_blocks_rebuild()
    test_runtime_upstream_ref_is_immutable()
    test_release_notes_do_not_repeat_first_release_copy()
    test_release_package_contains_changelog()
    print("ok - public release regression contracts")
