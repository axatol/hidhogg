#!/usr/bin/env python3

"""Bounded, non-launching preparation and capture helpers for SS-U0..SS-U3."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import tempfile
import time
import zlib
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import lldb as _lldb
except ImportError:
    _lldb = None


WORKSPACE_PARENT = Path("/private/tmp")
WORKSPACE_PREFIX = "ulanzi-screensaver."
ROOT_MARKER = ".hidhogg-ulanzi-screensaver-root"
ROOT_MARKER_CONTENT = "kind=ulanzi-screensaver-workspace\nversion=1\n"
SPECIMEN_DIRECTORY = "specimens"
FIXTURE_MANIFEST = "fixtures.json"
TRIAL_IDS = ("SS-U0", "SS-U1", "SS-U2", "SS-U3")
EXPECTED_SPECIMEN = {"SS-U0": None, "SS-U1": "A", "SS-U2": "B", "SS-U3": "A"}
ACTION_MARKERS = (
    "CLICK_SCREEN_SAVER",
    "PICKER_VISIBLE",
    "FILE_SELECTED",
    "EDITOR_VISIBLE",
    "SET_IMAGE_CLICKED",
    "CANCEL_CLICKED",
    "EDITOR_CLOSED",
    "DEVICE_OUTCOME_OBSERVED",
)
U0_MARKER_FLOW = (
    "CLICK_SCREEN_SAVER",
    "EDITOR_VISIBLE",
    "CANCEL_CLICKED",
    "EDITOR_CLOSED",
    "DEVICE_OUTCOME_OBSERVED",
)
UPLOAD_MARKER_FLOW = (
    "CLICK_SCREEN_SAVER",
    "EDITOR_VISIBLE",
    "PICKER_VISIBLE",
    "FILE_SELECTED",
    "EDITOR_VISIBLE",
    "SET_IMAGE_CLICKED",
    "EDITOR_CLOSED",
    "DEVICE_OUTCOME_OBSERVED",
)
OUTCOME_VALUES = ("A", "B", "UNCHANGED", "NOT_VISIBLE", "INDETERMINATE")
MAX_EVENTS = 256
MAX_DECLARED_LENGTH = 8 * 1024 * 1024
MAX_FIXTURE_BYTES = 16 * 1024 * 1024
MAX_LINE_BYTES = 8192
MAX_LOG_BYTES = MAX_LINE_BYTES * MAX_EVENTS
MAX_CALL_ORIGIN_LENGTH = 128
MAX_FIELD_VALUE_LENGTH = 160
MAX_TOTAL_PAYLOAD_BYTES = 32 * 1024 * 1024
MAX_BACKTRACE_FRAMES = 12
PNG_WIDTH = 1220
PNG_HEIGHT = 708
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
SAFE_CALL_ORIGIN = re.compile(r"[A-Za-z0-9_.$:<>? -]{1,128}\Z")
SAFE_COMMAND = re.compile(r"0[xX][0-9A-Fa-f]{4}\Z|[0-9]{1,5}\Z")
SAFE_FIELD_VALUE = re.compile(r"[A-Za-z0-9._:;,+ -]{0,160}\Z")
PAYLOAD_FILENAME = re.compile(r"payload-[0-9]{6}-outbound-[0-9a-f]{4}\.bin\Z")


class Refusal(Exception):
    """A requested operation violates a bounded workspace or evidence gate."""


def _refuse(message: str) -> None:
    raise Refusal(message)


def _require(condition: bool, message: str) -> None:
    if not condition:
        _refuse(message)


def _require_absolute_path(path: Path, label: str) -> Path:
    _require(path.is_absolute(), f"{label} must be absolute")
    _require(not path.is_symlink(), f"{label} must not be a symbolic link")
    return path


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def _require_owner_only(path: Path, label: str, exact: Optional[int] = None) -> None:
    mode = _mode(path)
    if exact is not None:
        _require(mode == exact, f"{label} must have mode {exact:04o}")
    else:
        _require(mode & 0o077 == 0, f"{label} must be owner-only")


def _require_directory(path: Path, label: str, exact_mode: int = 0o700) -> None:
    _require(not path.is_symlink() and path.is_dir(), f"{label} must be a directory")
    _require_owner_only(path, label, exact_mode)


def _require_regular_file(path: Path, label: str, max_bytes: Optional[int] = None) -> None:
    _require(not path.is_symlink() and path.is_file(), f"{label} must be a regular file")
    _require_owner_only(path, label)
    if max_bytes is not None:
        _require(path.stat().st_size <= max_bytes, f"{label} is too large")


def _read_text(path: Path, label: str, max_bytes: int = MAX_LINE_BYTES) -> str:
    _require_regular_file(path, label, max_bytes)
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise Refusal(f"unable to read {label}: {error}") from error


def validate_workspace_root(workspace: Path) -> Path:
    workspace = _require_absolute_path(workspace, "workspace path")
    _require(workspace.exists(), "workspace does not exist")
    _require(workspace.parent == WORKSPACE_PARENT, "workspace must be a direct child of /private/tmp")
    _require(workspace.name.startswith(WORKSPACE_PREFIX), "workspace name is not approved")
    _require_directory(workspace, "workspace", 0o700)
    marker = workspace / ROOT_MARKER
    _require_regular_file(marker, "workspace marker", MAX_LINE_BYTES)
    _require(_read_text(marker, "workspace marker") == ROOT_MARKER_CONTENT, "workspace marker is invalid")
    return workspace


def validate_workspace(workspace: Path, require_trials: bool = True) -> Path:
    workspace = validate_workspace_root(workspace)
    specimens = workspace / SPECIMEN_DIRECTORY
    _require_directory(specimens, "specimen directory", 0o700)
    if require_trials:
        for trial_id in TRIAL_IDS:
            trial = workspace / trial_id
            _require_directory(trial, f"trial directory {trial_id}", 0o700)
            _require_regular_file(trial / "worksheet.txt", f"{trial_id} worksheet", MAX_LINE_BYTES)
            _require_regular_file(trial / "markers.jsonl", f"{trial_id} marker log", MAX_LINE_BYTES)
    return workspace


def validate_trial(trial: Path, require_prepared: bool = False) -> Tuple[Path, str]:
    trial = _require_absolute_path(trial, "trial path")
    _require(trial.exists(), "trial directory does not exist")
    _require(trial.parent.parent == WORKSPACE_PARENT, "trial must be inside a marked /private/tmp workspace")
    workspace = validate_workspace(trial.parent, require_trials=True)
    trial_id = trial.name
    _require(trial_id in TRIAL_IDS and trial == workspace / trial_id, "unsafe or misplaced trial ID")
    _require_directory(trial, f"trial directory {trial_id}", 0o700)
    _require_regular_file(trial / "worksheet.txt", f"{trial_id} worksheet", MAX_LINE_BYTES)
    _require_regular_file(trial / "markers.jsonl", f"{trial_id} marker log", MAX_LINE_BYTES)
    if require_prepared:
        validate_prepared_capture(trial)
    return workspace, trial_id


def _exclusive_write(path: Path, contents: bytes, mode: int = 0o600) -> None:
    _require(not path.exists() and not path.is_symlink(), f"refusing overwrite: {path.name}")
    try:
        with path.open("xb") as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(path, mode)
    except FileExistsError as error:
        raise Refusal(f"refusing overwrite: {path.name}") from error
    except OSError as error:
        raise Refusal(f"unable to create {path.name}: {error}") from error


def _atomic_replace_owner_file(path: Path, contents: bytes, mode: int = 0o600) -> None:
    _require(not path.is_symlink(), f"refusing symbolic-link worksheet: {path.name}")
    temporary: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{path.name}.", dir=str(path.parent), delete=False
        ) as output:
            temporary = Path(output.name)
            os.chmod(temporary, mode)
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError as error:
        raise Refusal(f"unable to update {path.name}: {error}") from error
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def _pixel_a(x: int, y: int) -> Tuple[int, int, int, int]:
    center_x = PNG_WIDTH // 2
    center_y = PNG_HEIGHT // 2
    distance_x = abs(x - center_x)
    distance_y = abs(y - center_y)
    diagonal = distance_x * PNG_HEIGHT + distance_y * PNG_WIDTH
    diamond_edge = PNG_WIDTH * PNG_HEIGHT // 3
    ring_distance = (x - center_x) * (x - center_x) + (y - center_y) * (y - center_y)
    if diagonal < diamond_edge:
        return 38, 202, 214, 255
    if 36000 < ring_distance < 46000:
        return 250, 198, 74, 255
    if ((x + y) // 46) % 2 == 0:
        return 13, 39, 84, 255
    return 9, 24, 58, 255


def _pixel_b(x: int, y: int) -> Tuple[int, int, int, int]:
    center_x = PNG_WIDTH // 2
    triangle_y = y - 132
    triangle_half_width = max(0, triangle_y * 4 // 3)
    in_triangle = 0 <= triangle_y <= 410 and abs(x - center_x) <= triangle_half_width
    if in_triangle:
        return 169, 236, 102, 255
    if ((2 * x + y) // 58) % 2 == 0:
        return 219, 91, 65, 255
    if ((x - y) // 61) % 2 == 0:
        return 91, 31, 62, 255
    return 53, 18, 42, 255


def _fixture_png(specimen: str) -> bytes:
    pixel = _pixel_a if specimen == "A" else _pixel_b
    rows = bytearray()
    for y in range(PNG_HEIGHT):
        rows.append(0)
        for x in range(PNG_WIDTH):
            rows.extend(pixel(x, y))
    header = struct.pack(">IIBBBBB", PNG_WIDTH, PNG_HEIGHT, 8, 6, 0, 0, 0)
    compressed = zlib.compress(bytes(rows), level=9)
    return PNG_SIGNATURE + _png_chunk(b"IHDR", header) + _png_chunk(b"IDAT", compressed) + _png_chunk(b"IEND", b"")


def inspect_png(data: bytes) -> Tuple[int, int, bool]:
    _require(len(data) <= MAX_FIXTURE_BYTES, "fixture PNG is too large")
    _require(data.startswith(PNG_SIGNATURE), "fixture is not a PNG")
    offset = len(PNG_SIGNATURE)
    chunks: List[bytes] = []
    image_header: Optional[bytes] = None
    image_data = bytearray()
    while offset < len(data):
        _require(offset + 12 <= len(data), "fixture PNG has a truncated chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        offset += 4
        _require(offset + length + 8 <= len(data), "fixture PNG has an invalid chunk length")
        kind = data[offset : offset + 4]
        payload = data[offset + 4 : offset + 4 + length]
        checksum = struct.unpack(">I", data[offset + 4 + length : offset + 8 + length])[0]
        offset += length + 8
        _require(binascii.crc32(kind + payload) & 0xFFFFFFFF == checksum, "fixture PNG CRC mismatch")
        _require(kind in (b"IHDR", b"IDAT", b"IEND"), "fixture PNG contains metadata or an unsupported chunk")
        chunks.append(kind)
        if kind == b"IHDR":
            _require(image_header is None and length == 13, "fixture PNG has an invalid IHDR")
            image_header = payload
        elif kind == b"IDAT":
            image_data.extend(payload)
        else:
            _require(length == 0, "fixture PNG has a non-empty IEND")
    _require(offset == len(data), "fixture PNG has trailing bytes")
    _require(chunks == [b"IHDR", b"IDAT", b"IEND"], "fixture PNG chunk order is not metadata-free")
    _require(image_header is not None, "fixture PNG has no IHDR")
    width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
        ">IIBBBBB", image_header
    )
    _require(
        (width, height, bit_depth, color_type, compression, filter_method, interlace)
        == (PNG_WIDTH, PNG_HEIGHT, 8, 6, 0, 0, 0),
        "fixture PNG dimensions or encoding are invalid",
    )
    try:
        decoded = zlib.decompress(bytes(image_data))
    except zlib.error as error:
        raise Refusal(f"fixture PNG image data is invalid: {error}") from error
    expected_row_bytes = PNG_WIDTH * 4 + 1
    _require(len(decoded) == expected_row_bytes * PNG_HEIGHT, "fixture PNG pixel data is invalid")
    _require(all(decoded[y * expected_row_bytes] == 0 for y in range(PNG_HEIGHT)), "fixture PNG uses an unsupported filter")
    return width, height, True


# These values are filled from the fixed generator output and make accidental
# changes to the synthetic specimens fail before an owner can use them.
EXPECTED_FIXTURE_SHA256 = {
    "A": "eade72f0e93e4b136976460eeb5f6c8fa8db8171a7ff98741b3ce475e176b458",
    "B": "4ac5dcdcf09ebf25be40f7fab368e70e6cef27ba6727625e0a9bde4429e020bb",
}


def _fixture_manifest_data(workspace: Path) -> Dict[str, Any]:
    manifest_path = workspace / SPECIMEN_DIRECTORY / FIXTURE_MANIFEST
    text = _read_text(manifest_path, "fixture manifest", MAX_LINE_BYTES)
    try:
        manifest = json.loads(text)
    except json.JSONDecodeError as error:
        raise Refusal(f"fixture manifest is invalid: {error}") from error
    _require(isinstance(manifest, dict), "fixture manifest must be an object")
    _require(set(manifest) == {"fixtures", "version"}, "fixture manifest contains an unapproved field or identifier")
    _require(manifest.get("version") == 1, "fixture manifest version is invalid")
    fixtures = manifest.get("fixtures")
    _require(isinstance(fixtures, dict) and set(fixtures) == {"A", "B"}, "fixture manifest specimens are invalid")
    for specimen in ("A", "B"):
        entry = fixtures[specimen]
        _require(isinstance(entry, dict), f"fixture manifest entry {specimen} is invalid")
        _require(
            set(entry) == {"bytes", "filename", "geometry", "height", "metadata_free", "ownership", "sha256", "width"},
            f"fixture manifest entry {specimen} contains an unapproved field or identifier",
        )
        _require(entry.get("filename") == f"screensaver-{specimen}.png", f"fixture filename {specimen} is invalid")
        _require(entry.get("width") == PNG_WIDTH and entry.get("height") == PNG_HEIGHT, f"fixture dimensions {specimen} are invalid")
        _require(entry.get("ownership") == "project-owned", f"fixture ownership gate {specimen} is absent")
        _require(entry.get("metadata_free") is True, f"fixture metadata gate {specimen} is absent")
        _require(entry.get("geometry") == ({"A": "diamond-ring", "B": "triangle-bands"}[specimen]), f"fixture geometry {specimen} is invalid")
        _require(isinstance(entry.get("bytes"), int) and entry["bytes"] > 0, f"fixture byte count {specimen} is invalid")
        _require(entry.get("sha256") == EXPECTED_FIXTURE_SHA256[specimen], f"fixture hash {specimen} is not approved")
        fixture_path = workspace / SPECIMEN_DIRECTORY / entry["filename"]
        _require_regular_file(fixture_path, f"fixture {specimen}", MAX_FIXTURE_BYTES)
        data = fixture_path.read_bytes()
        inspect_png(data)
        _require(len(data) == entry["bytes"], f"fixture byte count {specimen} does not match")
        _require(hashlib.sha256(data).hexdigest() == entry["sha256"], f"fixture hash {specimen} does not match")
    return manifest


def verify_fixtures(workspace: Path) -> Dict[str, Any]:
    workspace = validate_workspace(workspace, require_trials=False)
    return _fixture_manifest_data(workspace)


def generate_fixtures(workspace: Path) -> Dict[str, Any]:
    workspace = validate_workspace(workspace, require_trials=False)
    specimen_dir = workspace / SPECIMEN_DIRECTORY
    paths = {specimen: specimen_dir / f"screensaver-{specimen}.png" for specimen in ("A", "B")}
    manifest_path = specimen_dir / FIXTURE_MANIFEST
    for path in (*paths.values(), manifest_path):
        _require(not path.exists() and not path.is_symlink(), f"refusing overwrite: {path.name}")
    images = {specimen: _fixture_png(specimen) for specimen in ("A", "B")}
    for specimen, data in images.items():
        digest = hashlib.sha256(data).hexdigest()
        _require(digest == EXPECTED_FIXTURE_SHA256[specimen], f"generated fixture {specimen} hash is not approved")
        inspect_png(data)
    manifest = {
        "version": 1,
        "fixtures": {
            "A": {
                "filename": "screensaver-A.png",
                "width": PNG_WIDTH,
                "height": PNG_HEIGHT,
                "bytes": len(images["A"]),
                "sha256": hashlib.sha256(images["A"]).hexdigest(),
                "metadata_free": True,
                "ownership": "project-owned",
                "geometry": "diamond-ring",
            },
            "B": {
                "filename": "screensaver-B.png",
                "width": PNG_WIDTH,
                "height": PNG_HEIGHT,
                "bytes": len(images["B"]),
                "sha256": hashlib.sha256(images["B"]).hexdigest(),
                "metadata_free": True,
                "ownership": "project-owned",
                "geometry": "triangle-bands",
            },
        },
    }
    for specimen, data in images.items():
        _exclusive_write(paths[specimen], data)
    manifest_bytes = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    _exclusive_write(manifest_path, manifest_bytes)
    return verify_fixtures(workspace)


def _worksheet_lines(trial_id: str) -> List[str]:
    specimen = EXPECTED_SPECIMEN[trial_id] or "none"
    lines = [
        "worksheet_version=1",
        f"trial_id={trial_id}",
        "capture_window_before_first_action_seconds=15",
        "capture_window_after_commit_or_cancel_seconds=30",
        "application_boundary_outbound=sendDataToDeck",
        "application_boundary_inbound=OnDeckFrameReceived",
        f"expected_specimen={specimen}",
        "specimen_sha256=not-recorded",
        "capture_prepared=no",
        "payload_capture_armed=no",
    ]
    lines.extend(f"{marker}=not-recorded" for marker in ACTION_MARKERS)
    lines.extend(
        [
            "device_outcome=not-recorded",
            "uncertainties=not-recorded",
        ]
    )
    return lines


def create_workspace() -> Path:
    workspace: Optional[Path] = None
    try:
        workspace = Path(tempfile.mkdtemp(prefix=WORKSPACE_PREFIX, dir=str(WORKSPACE_PARENT)))
        os.chmod(workspace, 0o700)
        _exclusive_write(workspace / ROOT_MARKER, ROOT_MARKER_CONTENT.encode("utf-8"))
        specimen_dir = workspace / SPECIMEN_DIRECTORY
        specimen_dir.mkdir(mode=0o700)
        os.chmod(specimen_dir, 0o700)
        for trial_id in TRIAL_IDS:
            trial = workspace / trial_id
            trial.mkdir(mode=0o700)
            os.chmod(trial, 0o700)
            _exclusive_write(trial / "worksheet.txt", ("\n".join(_worksheet_lines(trial_id)) + "\n").encode("utf-8"))
            _exclusive_write(trial / "markers.jsonl", b"")
        generate_fixtures(workspace)
        return workspace
    except Exception:
        if workspace is not None and workspace.parent == WORKSPACE_PARENT and workspace.name.startswith(WORKSPACE_PREFIX):
            shutil.rmtree(workspace, ignore_errors=True)
        raise


def _fixture_summary(workspace: Path) -> Dict[str, Any]:
    manifest = verify_fixtures(workspace)
    return {
        "workspace_root": str(workspace),
        "fixture_A_sha256": manifest["fixtures"]["A"]["sha256"],
        "fixture_B_sha256": manifest["fixtures"]["B"]["sha256"],
        "fixture_height": PNG_HEIGHT,
        "fixture_width": PNG_WIDTH,
    }


def _require_specimen_gate(trial_id: str, specimen: Optional[str]) -> str:
    expected = EXPECTED_SPECIMEN[trial_id]
    if expected is None:
        _require(specimen is None, f"{trial_id} does not accept a specimen argument")
        return "none"
    _require(specimen in ("A", "B"), "specimen must be A or B")
    _require(specimen == expected, f"{trial_id} requires specimen {expected}")
    return expected


def _prepared_paths(trial: Path) -> Iterable[Path]:
    yield trial / "capture-contract.txt"
    yield trial / "chronology.lldb"
    yield trial / "payload.lldb"
    yield trial / "chronology.jsonl"
    yield trial / "payload-captures.jsonl"
    yield trial / "payload-authorization.json"
    yield trial / "workflow.closed"


def prepare_capture(trial: Path, specimen: Optional[str]) -> Dict[str, str]:
    workspace, trial_id = validate_trial(trial, require_prepared=False)
    specimen = _require_specimen_gate(trial_id, specimen)
    verify_fixtures(workspace)
    _require(not (trial / "payloads").exists(), "refusing overwrite: payload directory already exists")
    for path in _prepared_paths(trial):
        _require(not path.exists() and not path.is_symlink(), f"refusing overwrite: {path.name}")
    payload_dir = trial / "payloads"
    payload_dir.mkdir(mode=0o700)
    os.chmod(payload_dir, 0o700)
    chronology_command = "\n".join(
        [
            "# Metadata-only application-boundary chronology; auto-continue is enabled by the callback.",
            "command script import scripts/diagnostics/ulanzi-lldb/screensaver_capture.py",
            f"hidhogg-screensaver-chronology --trial-dir {trial}",
            "",
        ]
    ).encode("utf-8")
    payload_command = "\n".join(
        [
            "# Explicitly authorized stopped-payload capture; the callback never continues.",
            "command script import scripts/diagnostics/ulanzi-lldb/screensaver_capture.py",
            f"hidhogg-screensaver-payload --trial-dir {trial} --specimen {specimen}",
            "",
        ]
    ).encode("utf-8")
    contract = "\n".join(
        [
            "contract_version=1",
            f"trial_id={trial_id}",
            f"specimen={specimen}",
            "chronology_mode=metadata-only",
            "chronology_auto_continue=yes",
            "payload_mode=stopped-only",
            "payload_auto_continue=no",
            "application_boundary_outbound=sendDataToDeck",
            "application_boundary_inbound=OnDeckFrameReceived",
            "capture_window_before_first_action_seconds=15",
            "capture_window_after_commit_or_cancel_seconds=30",
            f"max_events={MAX_EVENTS}",
            f"max_declared_length={MAX_DECLARED_LENGTH}",
            f"max_total_payload_bytes={MAX_TOTAL_PAYLOAD_BYTES}",
            "payload_attribution_marker=FILE_SELECTED+SET_IMAGE_CLICKED+payload-authorization.json",
            "application_launch=prohibited",
            "application_attach=prohibited",
            "device_io=prohibited",
            "network_io=prohibited",
            "",
        ]
    ).encode("utf-8")
    _exclusive_write(trial / "capture-contract.txt", contract)
    _exclusive_write(trial / "chronology.lldb", chronology_command)
    _exclusive_write(trial / "payload.lldb", payload_command)
    _exclusive_write(trial / "chronology.jsonl", b"")
    _exclusive_write(trial / "payload-captures.jsonl", b"")
    worksheet = _load_worksheet(trial)
    worksheet["capture_prepared"] = "yes"
    worksheet["specimen_sha256"] = _fixture_hash(workspace, specimen) if specimen != "none" else "none"
    _write_worksheet(trial, worksheet)
    return {
        "trial_id": trial_id,
        "trial_dir": str(trial),
        "chronology_command_file": str(trial / "chronology.lldb"),
        "payload_command_file": str(trial / "payload.lldb"),
        "specimen": specimen,
    }


def validate_prepared_capture(trial: Path) -> None:
    workspace, trial_id = validate_trial(trial, require_prepared=False)
    verify_fixtures(workspace)
    contract = _read_text(trial / "capture-contract.txt", "capture contract", MAX_LINE_BYTES)
    contract_values: Dict[str, str] = {}
    for line in contract.splitlines():
        _require("=" in line, "capture contract contains an invalid field")
        key, value = line.split("=", 1)
        _require(key not in contract_values, "capture contract contains a duplicate field")
        contract_values[key] = value
    _require(
        set(contract_values)
        == {
            "application_attach",
            "application_boundary_inbound",
            "application_boundary_outbound",
            "application_launch",
            "capture_window_after_commit_or_cancel_seconds",
            "capture_window_before_first_action_seconds",
            "chronology_auto_continue",
            "chronology_mode",
            "contract_version",
            "device_io",
            "max_declared_length",
            "max_events",
            "max_total_payload_bytes",
            "network_io",
            "payload_attribution_marker",
            "payload_auto_continue",
            "payload_mode",
            "specimen",
            "trial_id",
        },
        "capture contract contains an unapproved field or identifier",
    )
    _require(contract_values.get("trial_id") == trial_id, "capture contract trial gate is invalid")
    _require(contract_values.get("specimen") == (EXPECTED_SPECIMEN[trial_id] or "none"), "capture contract specimen gate is invalid")
    _require(contract_values.get("contract_version") == "1", "capture contract version is invalid")
    _require(contract_values.get("chronology_auto_continue") == "yes", "chronology auto-continue gate is absent")
    _require(contract_values.get("payload_auto_continue") == "no", "stopped-payload gate is absent")
    _require(contract_values.get("capture_window_before_first_action_seconds") == "15", "capture start window is invalid")
    _require(contract_values.get("capture_window_after_commit_or_cancel_seconds") == "30", "capture end window is invalid")
    _require(contract_values.get("chronology_mode") == "metadata-only", "chronology mode is invalid")
    _require(contract_values.get("payload_mode") == "stopped-only", "payload mode is invalid")
    _require(contract_values.get("application_boundary_outbound") == "sendDataToDeck", "outbound boundary is invalid")
    _require(contract_values.get("application_boundary_inbound") == "OnDeckFrameReceived", "inbound boundary is invalid")
    _require(contract_values.get("application_launch") == "prohibited", "application launch gate is invalid")
    _require(contract_values.get("application_attach") == "prohibited", "application attach gate is invalid")
    _require(contract_values.get("device_io") == "prohibited", "device I/O gate is invalid")
    _require(contract_values.get("network_io") == "prohibited", "network I/O gate is invalid")
    _require(contract_values.get("max_events") == str(MAX_EVENTS), "event bound is invalid")
    _require(contract_values.get("max_declared_length") == str(MAX_DECLARED_LENGTH), "payload bound is invalid")
    _require(contract_values.get("max_total_payload_bytes") == str(MAX_TOTAL_PAYLOAD_BYTES), "total payload bound is invalid")
    _require(
        contract_values.get("payload_attribution_marker")
        == "FILE_SELECTED+SET_IMAGE_CLICKED+payload-authorization.json",
        "payload attribution gate is invalid",
    )
    _require_regular_file(trial / "chronology.lldb", "chronology command file", MAX_LINE_BYTES)
    _require_regular_file(trial / "payload.lldb", "payload command file", MAX_LINE_BYTES)
    _require_regular_file(trial / "chronology.jsonl", "chronology log", MAX_LOG_BYTES)
    _require_regular_file(trial / "payload-captures.jsonl", "payload log", MAX_LOG_BYTES)
    _require_directory(trial / "payloads", "payload directory", 0o700)
    _validate_payload_artifacts(trial, workspace, trial_id)


def _fixture_hash(workspace: Path, specimen: str) -> str:
    _require(specimen in ("A", "B"), "fixture specimen is invalid")
    manifest = verify_fixtures(workspace)
    return manifest["fixtures"][specimen]["sha256"]


def _load_worksheet(trial: Path) -> Dict[str, str]:
    text = _read_text(trial / "worksheet.txt", "worksheet", MAX_LINE_BYTES)
    values: Dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        _require("=" in line, "worksheet contains an invalid field")
        key, value = line.split("=", 1)
        _require(bool(SAFE_COMPONENT.fullmatch(key)), "worksheet contains an unsafe field")
        _require(bool(SAFE_FIELD_VALUE.fullmatch(value)), "worksheet contains an unsafe value or identifier")
        values[key] = value
    return values


def _write_worksheet(trial: Path, values: Dict[str, str]) -> None:
    keys = [line.split("=", 1)[0] for line in _worksheet_lines(trial.name)]
    _require(set(values).issubset(set(keys)), "worksheet contains an unapproved field")
    for key, value in values.items():
        _require(bool(SAFE_COMPONENT.fullmatch(key)), "worksheet contains an unsafe field")
        _require(isinstance(value, str), "worksheet contains a non-text field")
        _require(len(value) <= MAX_FIELD_VALUE_LENGTH and bool(SAFE_FIELD_VALUE.fullmatch(value)), "worksheet contains an unsafe value or identifier")
    contents = "\n".join(f"{key}={values.get(key, 'not-recorded')}" for key in keys) + "\n"
    _atomic_replace_owner_file(trial / "worksheet.txt", contents.encode("utf-8"))


def _load_json_lines(path: Path, label: str) -> List[Dict[str, Any]]:
    text = _read_text(path, label, MAX_LOG_BYTES)
    records: List[Dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        _require(len(line.encode("utf-8")) <= MAX_LINE_BYTES, f"{label} line is too large")
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise Refusal(f"{label} line {line_number} is invalid: {error}") from error
        _require(isinstance(record, dict), f"{label} line {line_number} is not an object")
        records.append(record)
    _require(len(records) <= MAX_EVENTS, f"{label} exceeds the bounded event count")
    return records


def _latest_marker(records: Sequence[Dict[str, Any]]) -> str:
    if not records:
        return "NONE"
    return str(records[-1]["marker"])


def _marker_flow(trial_id: str) -> Tuple[str, ...]:
    return U0_MARKER_FLOW if trial_id == "SS-U0" else UPLOAD_MARKER_FLOW


def _validate_marker_records(trial_id: str, records: Sequence[Dict[str, Any]]) -> None:
    flow = _marker_flow(trial_id)
    _require(len(records) <= len(flow), "marker workflow is already closed")
    previous_time = -1
    for sequence, record in enumerate(records, 1):
        _require(
            set(record).issubset({"marker", "monotonic_ns", "outcome", "sequence", "specimen"}),
            "marker contains an unapproved field or identifier",
        )
        _require(isinstance(record.get("sequence"), int) and not isinstance(record["sequence"], bool), "marker sequence is invalid")
        _require(record.get("sequence") == sequence, "marker sequence is not contiguous")
        _require(record.get("marker") == flow[sequence - 1], "marker is out of order")
        _require(
            isinstance(record.get("monotonic_ns"), int)
            and not isinstance(record["monotonic_ns"], bool)
            and record["monotonic_ns"] >= previous_time,
            "marker time is invalid",
        )
        previous_time = record["monotonic_ns"]
        if record["marker"] == "FILE_SELECTED":
            _require(record.get("specimen") in ("A", "B"), "file selection specimen is missing")
        else:
            _require("specimen" not in record, "specimen is only allowed on FILE_SELECTED")
        if record["marker"] == "DEVICE_OUTCOME_OBSERVED":
            _require(record.get("outcome") in OUTCOME_VALUES, "device outcome is invalid")
        else:
            _require("outcome" not in record, "outcome is only allowed on DEVICE_OUTCOME_OBSERVED")


def _append_json_line(path: Path, record: Dict[str, Any], label: str) -> None:
    _require_regular_file(path, label, MAX_LOG_BYTES)
    encoded = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    _require(len(encoded) <= MAX_LINE_BYTES, f"{label} record is too large")
    try:
        with path.open("ab") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise Refusal(f"unable to append {label}: {error}") from error


def _authorization_path(trial: Path) -> Path:
    return trial / "payload-authorization.json"


def _selection_digest(record: Dict[str, Any]) -> str:
    encoded = json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _current_file_selection(trial_id: str, records: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    selected = [record for record in records if record["marker"] == "FILE_SELECTED"]
    _require(len(selected) == 1, "current FILE_SELECTED specimen is missing or ambiguous")
    expected = EXPECTED_SPECIMEN[trial_id]
    _require(expected in ("A", "B"), "current FILE_SELECTED specimen is unavailable for this trial")
    _require(selected[0].get("specimen") == expected, "current FILE_SELECTED specimen does not match the prepared gate")
    return selected[0]


def _arm_payload(trial: Path, specimen: str, records: Sequence[Dict[str, Any]]) -> None:
    workspace, trial_id = validate_trial(trial, require_prepared=True)
    expected = _require_specimen_gate(trial_id, specimen)
    _validate_marker_records(trial_id, records)
    selected = _current_file_selection(trial_id, records)
    _require(not any(record["marker"] == "DEVICE_OUTCOME_OBSERVED" for record in records), "workflow is already closed")
    authorization = {
        "version": 1,
        "trial_id": trial_id,
        "specimen": expected,
        "fixture_sha256": _fixture_hash(workspace, expected),
        "authorized_by_marker": "FILE_SELECTED",
        "requires_marker": "SET_IMAGE_CLICKED",
        "selected_sequence": selected["sequence"],
        "selected_monotonic_ns": selected["monotonic_ns"],
        "selection_sha256": _selection_digest(selected),
    }
    _exclusive_write(_authorization_path(trial), (json.dumps(authorization, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))
    worksheet = _load_worksheet(trial)
    worksheet["payload_capture_armed"] = "yes"
    _write_worksheet(trial, worksheet)


def arm_payload(trial: Path, specimen: str) -> Dict[str, bool]:
    validate_trial(trial, require_prepared=True)
    records = _load_json_lines(trial / "markers.jsonl", "marker log")
    _arm_payload(trial, specimen, records)
    return {"armed": True}


def mark_action(
    trial: Path,
    marker: str,
    specimen: Optional[str] = None,
    outcome: Optional[str] = None,
    arm_payload: bool = False,
) -> Dict[str, Any]:
    workspace, trial_id = validate_trial(trial, require_prepared=True)
    _require(marker in ACTION_MARKERS, "unknown action marker")
    records = _load_json_lines(trial / "markers.jsonl", "marker log")
    _validate_marker_records(trial_id, records)
    flow = _marker_flow(trial_id)
    _require(len(records) < len(flow), "marker workflow is already closed")
    _require(marker == flow[len(records)], "action marker is out of order")
    if marker == "FILE_SELECTED":
        expected = _require_specimen_gate(trial_id, specimen)
    else:
        _require(specimen is None, "specimen is allowed only with FILE_SELECTED")
        expected = None
    if marker == "DEVICE_OUTCOME_OBSERVED":
        _require(outcome in OUTCOME_VALUES, "device outcome is required and must be bounded")
    else:
        _require(outcome is None, "outcome is allowed only with DEVICE_OUTCOME_OBSERVED")
    if arm_payload:
        _require(marker == "FILE_SELECTED", "payload authorization can only follow FILE_SELECTED")
        _require(expected is not None, "payload authorization requires a specimen")
        _require(not _authorization_path(trial).exists(), "refusing overwrite: payload authorization already exists")
    sequence = len(records) + 1
    record: Dict[str, Any] = {
        "marker": marker,
        "monotonic_ns": time.monotonic_ns(),
        "sequence": sequence,
    }
    if expected is not None:
        record["specimen"] = expected
    if outcome is not None:
        record["outcome"] = outcome
    previous_marker_time = records[-1]["monotonic_ns"] if records else -1
    _require(
        isinstance(record["monotonic_ns"], int)
        and not isinstance(record["monotonic_ns"], bool)
        and record["monotonic_ns"] >= previous_marker_time,
        "marker time is invalid",
    )
    _append_json_line(trial / "markers.jsonl", record, "marker log")
    worksheet = _load_worksheet(trial)
    worksheet[marker] = f"sequence:{sequence};monotonic_ns:{record['monotonic_ns']}"
    if expected is not None:
        worksheet["specimen_sha256"] = _fixture_hash(workspace, expected)
    if outcome is not None:
        worksheet["device_outcome"] = outcome
    _write_worksheet(trial, worksheet)
    if arm_payload:
        _arm_payload(trial, expected, list(records) + [record])
    if marker == "DEVICE_OUTCOME_OBSERVED":
        _exclusive_write(trial / "workflow.closed", b"closed\n")
    return record


def _parse_command(command: str) -> Tuple[int, int]:
    _require(bool(SAFE_COMMAND.fullmatch(command)), "command must be a four-digit hexadecimal command")
    value = int(command, 0) if command.lower().startswith("0x") else int(command, 10)
    _require(0 <= value <= 0xFFFF, "command is outside the two-byte range")
    return (value >> 8) & 0xFF, value & 0xFF


def _command_text(command: Tuple[int, int]) -> str:
    return f"0x{command[0]:02x}{command[1]:02x}"


def _validate_direction(direction: str) -> str:
    _require(direction in ("inbound", "outbound"), "direction must be inbound or outbound")
    return direction


def _validate_call_origin(call_origin: str) -> str:
    _require(len(call_origin) <= MAX_CALL_ORIGIN_LENGTH and bool(SAFE_CALL_ORIGIN.fullmatch(call_origin)), "call origin contains an unsafe identifier or path")
    return call_origin


def _validate_declared_length(declared_length: int) -> int:
    _require(isinstance(declared_length, int) and not isinstance(declared_length, bool), "declared length must be an integer")
    _require(0 <= declared_length <= MAX_DECLARED_LENGTH, "declared length exceeds the bounded capture limit")
    return declared_length


def _validate_command(command: Tuple[int, int]) -> Tuple[int, int]:
    _require(
        isinstance(command, tuple)
        and len(command) == 2
        and all(isinstance(value, int) and not isinstance(value, bool) for value in command),
        "command must contain two integer bytes",
    )
    _require(all(0 <= value <= 0xFF for value in command), "command byte is outside the byte range")
    return command


def _next_record_sequence(path: Path, label: str) -> Tuple[List[Dict[str, Any]], int]:
    records = _load_json_lines(path, label)
    if records:
        for sequence, record in enumerate(records, 1):
            _require(record.get("sequence") == sequence, f"{label} sequence is not contiguous")
    return records, len(records) + 1


def _validate_chronology_records(records: Sequence[Dict[str, Any]]) -> None:
    allowed = {
        "action_marker",
        "call_origin",
        "capture_name",
        "classification",
        "command",
        "declared_length",
        "direction",
        "payload_captured",
        "sequence",
        "time_monotonic_ns",
    }
    previous_time = -1
    for record in records:
        _require(set(record) == allowed, "chronology contains an unapproved field or identifier")
        _require(record.get("action_marker") == "NONE" or record.get("action_marker") in ACTION_MARKERS, "chronology marker is invalid")
        _validate_call_origin(record["call_origin"])
        _require(bool(re.fullmatch(r"chronology-[0-9]{6}-(inbound|outbound)-[0-9a-f]{4}\Z", record["capture_name"])), "chronology capture name is invalid")
        _require(record["classification"] == "observed-chronology", "chronology classification is invalid")
        _parse_command(record["command"])
        _validate_declared_length(record["declared_length"])
        _validate_direction(record["direction"])
        _require(record["payload_captured"] is False, "chronology payload capture is not permitted")
        _require(isinstance(record["sequence"], int) and not isinstance(record["sequence"], bool) and record["sequence"] >= 1, "chronology sequence is invalid")
        _require(isinstance(record["time_monotonic_ns"], int) and not isinstance(record["time_monotonic_ns"], bool) and record["time_monotonic_ns"] >= previous_time, "chronology time is invalid")
        previous_time = record["time_monotonic_ns"]


def _payload_artifact_names(trial: Path) -> set:
    payload_dir = trial / "payloads"
    _require_directory(payload_dir, "payload directory", 0o700)
    try:
        children = list(payload_dir.iterdir())
    except OSError as error:
        raise Refusal(f"unable to enumerate payload directory: {error}") from error
    names = set()
    for child in children:
        _require(bool(PAYLOAD_FILENAME.fullmatch(child.name)), "payload directory contains an orphan or unsafe artifact")
        _require_regular_file(child, f"payload artifact {child.name}", MAX_DECLARED_LENGTH)
        names.add(child.name)
    return names


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        raise Refusal(f"unable to hash payload artifact {path.name}: {error}") from error
    return digest.hexdigest()


def _validate_payload_records(
    trial: Path,
    authorization: Dict[str, Any],
    records: Sequence[Dict[str, Any]],
    artifact_names: Optional[set] = None,
) -> None:
    allowed = {
        "attribution_fixture_sha256",
        "attribution_marker",
        "attribution_selected_monotonic_ns",
        "attribution_selected_sequence",
        "attribution_selection_sha256",
        "attribution_specimen",
        "auto_continue",
        "call_origin",
        "capture_name",
        "classification",
        "command",
        "declared_length",
        "direction",
        "payload_bytes",
        "payload_sha256",
        "sequence",
        "time_monotonic_ns",
    }
    previous_time = -1
    capture_names = set()
    total_payload_bytes = 0
    if artifact_names is None:
        artifact_names = _payload_artifact_names(trial)
    for record in records:
        _require(set(record) == allowed, "payload log contains an unapproved field or identifier")
        _require(record["attribution_marker"] == "FILE_SELECTED+SET_IMAGE_CLICKED", "payload attribution marker is invalid")
        _require(record["attribution_specimen"] == authorization["specimen"], "payload attribution specimen is not authorized")
        _require(record["attribution_fixture_sha256"] == authorization["fixture_sha256"], "payload attribution fixture is not authorized")
        _require(
            isinstance(record["attribution_selected_sequence"], int)
            and not isinstance(record["attribution_selected_sequence"], bool)
            and record["attribution_selected_sequence"] >= 1,
            "payload selection sequence is invalid",
        )
        _require(
            isinstance(record["attribution_selected_monotonic_ns"], int)
            and not isinstance(record["attribution_selected_monotonic_ns"], bool)
            and record["attribution_selected_monotonic_ns"] >= 0,
            "payload selection time is invalid",
        )
        _require(record["attribution_selected_sequence"] == authorization["selected_sequence"], "payload selection sequence is not authorized")
        _require(record["attribution_selected_monotonic_ns"] == authorization["selected_monotonic_ns"], "payload selection time is not authorized")
        _require(record["attribution_selection_sha256"] == authorization["selection_sha256"], "payload selection binding is not authorized")
        _require(record["auto_continue"] is False, "payload mode must remain stopped")
        _validate_call_origin(record["call_origin"])
        _require(bool(PAYLOAD_FILENAME.fullmatch(record["capture_name"])), "payload capture name is invalid")
        _require(record["classification"] == "captured-bytes", "payload classification is invalid")
        _parse_command(record["command"])
        _validate_declared_length(record["declared_length"])
        _require(record["declared_length"] > 0, "payload declared length must be non-zero")
        _require(record["direction"] == "outbound", "payload direction is invalid")
        _require(isinstance(record["payload_bytes"], int) and not isinstance(record["payload_bytes"], bool), "payload byte count is invalid")
        _require(record["payload_bytes"] == record["declared_length"], "payload byte count is invalid")
        _require(bool(re.fullmatch(r"[0-9a-f]{64}\Z", record["payload_sha256"])), "payload hash is invalid")
        _require(isinstance(record["sequence"], int) and not isinstance(record["sequence"], bool) and record["sequence"] >= 1, "payload sequence is invalid")
        _require(record["sequence"] == len(capture_names) + 1, "payload sequence is not contiguous")
        _require(isinstance(record["time_monotonic_ns"], int) and not isinstance(record["time_monotonic_ns"], bool) and record["time_monotonic_ns"] >= previous_time, "payload time is invalid")
        expected_name = f"payload-{record['sequence']:06d}-outbound-{_parse_command(record['command'])[0]:02x}{_parse_command(record['command'])[1]:02x}.bin"
        _require(record["capture_name"] == expected_name, "payload capture name does not match its sequence and command")
        _require(record["capture_name"] not in capture_names, "payload capture name is duplicated")
        payload_path = trial / "payloads" / record["capture_name"]
        _require(payload_path.parent == trial / "payloads", "payload artifact path escaped its directory")
        _require_regular_file(payload_path, f"payload artifact {record['capture_name']}", MAX_DECLARED_LENGTH)
        _require(payload_path.stat().st_size == record["payload_bytes"], "payload artifact size does not match its log row")
        _require(_file_sha256(payload_path) == record["payload_sha256"], "payload artifact hash does not match its log row")
        capture_names.add(record["capture_name"])
        total_payload_bytes += record["payload_bytes"]
        previous_time = record["time_monotonic_ns"]
    _require(total_payload_bytes <= MAX_TOTAL_PAYLOAD_BYTES, "payload storage limit is exceeded")
    _require(capture_names == artifact_names, "payload log rows and payload artifacts do not match exactly")


def _validate_payload_artifacts(trial: Path, workspace: Path, trial_id: str) -> None:
    records = _load_json_lines(trial / "payload-captures.jsonl", "payload log")
    artifact_names = _payload_artifact_names(trial)
    if not records:
        _require(not artifact_names, "payload directory contains an orphan artifact")
        return
    expected = EXPECTED_SPECIMEN[trial_id]
    _require(expected in ("A", "B"), "payload log is not permitted for this trial")
    marker_records = _load_json_lines(trial / "markers.jsonl", "marker log")
    _validate_marker_records(trial_id, marker_records)
    marker_names = [record["marker"] for record in marker_records]
    _require("FILE_SELECTED" in marker_names, "file selection gate is missing")
    _require("SET_IMAGE_CLICKED" in marker_names, "explicit commit marker is missing")
    authorization = _read_authorization(trial, workspace, trial_id, expected)
    _validate_payload_records(trial, authorization, records, artifact_names)


def record_chronology_event(
    trial: Path,
    direction: str,
    command: Tuple[int, int],
    declared_length: int,
    call_origin: str,
    time_ns: Optional[int] = None,
) -> Dict[str, Any]:
    workspace, trial_id = validate_trial(trial, require_prepared=True)
    _validate_direction(direction)
    _validate_command(command)
    _validate_declared_length(declared_length)
    _validate_call_origin(call_origin)
    records, sequence = _next_record_sequence(trial / "chronology.jsonl", "chronology log")
    _validate_chronology_records(records)
    _require(sequence <= MAX_EVENTS, "chronology event limit reached")
    current_time = time.monotonic_ns() if time_ns is None else time_ns
    _require(isinstance(current_time, int) and not isinstance(current_time, bool) and current_time >= 0, "chronology time is invalid")
    if records:
        _require(current_time >= records[-1]["time_monotonic_ns"], "chronology time moved backwards")
    capture_name = f"chronology-{sequence:06d}-{direction}-{_command_text(command)[2:]}"
    existing_names = {str(record.get("capture_name")) for record in records}
    _require(capture_name not in existing_names, "chronology capture name collision")
    marker_records = _load_json_lines(trial / "markers.jsonl", "marker log")
    _validate_marker_records(trial_id, marker_records)
    event = {
        "action_marker": _latest_marker(marker_records),
        "call_origin": call_origin,
        "capture_name": capture_name,
        "classification": "observed-chronology",
        "command": _command_text(command),
        "declared_length": declared_length,
        "direction": direction,
        "payload_captured": False,
        "sequence": sequence,
        "time_monotonic_ns": current_time,
    }
    _append_json_line(trial / "chronology.jsonl", event, "chronology log")
    return event


def _read_authorization(trial: Path, workspace: Path, trial_id: str, specimen: str) -> Dict[str, Any]:
    path = _authorization_path(trial)
    _require_regular_file(path, "payload authorization", MAX_LINE_BYTES)
    try:
        authorization = json.loads(_read_text(path, "payload authorization"))
    except json.JSONDecodeError as error:
        raise Refusal(f"payload authorization is invalid: {error}") from error
    _require(isinstance(authorization, dict), "payload authorization must be an object")
    _require(
        set(authorization)
        == {
            "authorized_by_marker",
            "fixture_sha256",
            "requires_marker",
            "selected_monotonic_ns",
            "selected_sequence",
            "selection_sha256",
            "specimen",
            "trial_id",
            "version",
        },
        "payload authorization contains an unapproved field or identifier",
    )
    _require(authorization.get("version") == 1, "payload authorization version is invalid")
    _require(authorization.get("trial_id") == trial_id, "payload authorization trial is invalid")
    _require(authorization.get("specimen") == specimen, "payload authorization specimen is invalid")
    _require(authorization.get("authorized_by_marker") == "FILE_SELECTED", "payload authorization marker is invalid")
    _require(authorization.get("requires_marker") == "SET_IMAGE_CLICKED", "payload authorization commit gate is invalid")
    _require(authorization.get("fixture_sha256") == _fixture_hash(workspace, specimen), "payload authorization fixture hash is invalid")
    _require(
        isinstance(authorization.get("selected_sequence"), int)
        and not isinstance(authorization["selected_sequence"], bool)
        and authorization["selected_sequence"] >= 1,
        "payload authorization selection sequence is invalid",
    )
    _require(
        isinstance(authorization.get("selected_monotonic_ns"), int)
        and not isinstance(authorization["selected_monotonic_ns"], bool)
        and authorization["selected_monotonic_ns"] >= 0,
        "payload authorization selection time is invalid",
    )
    _require(bool(re.fullmatch(r"[0-9a-f]{64}\Z", authorization["selection_sha256"])), "payload authorization selection binding is invalid")
    marker_records = _load_json_lines(trial / "markers.jsonl", "marker log")
    _validate_marker_records(trial_id, marker_records)
    selected = _current_file_selection(trial_id, marker_records)
    _require(authorization["specimen"] == selected["specimen"], "payload authorization specimen is stale")
    _require(authorization["selected_sequence"] == selected["sequence"], "payload authorization selection sequence is stale")
    _require(authorization["selected_monotonic_ns"] == selected["monotonic_ns"], "payload authorization selection time is stale")
    _require(authorization["selection_sha256"] == _selection_digest(selected), "payload authorization selection binding is stale")
    return authorization


def record_payload_event(
    trial: Path,
    direction: str,
    command: Tuple[int, int],
    declared_length: int,
    call_origin: str,
    payload: bytes,
    time_ns: Optional[int] = None,
) -> Dict[str, Any]:
    workspace, trial_id = validate_trial(trial, require_prepared=True)
    _require(_validate_direction(direction) == "outbound", "stopped-payload mode accepts outbound records only")
    _validate_command(command)
    _validate_declared_length(declared_length)
    _require(declared_length > 0, "stopped-payload mode requires a non-empty attributable payload")
    _validate_call_origin(call_origin)
    _require(isinstance(payload, bytes), "payload must be bytes")
    _require(len(payload) == declared_length, "payload length does not match declared length")
    _require(len(payload) <= MAX_DECLARED_LENGTH, "payload exceeds the bounded capture limit")
    current_time = time.monotonic_ns() if time_ns is None else time_ns
    _require(isinstance(current_time, int) and not isinstance(current_time, bool) and current_time >= 0, "payload time is invalid")
    expected = EXPECTED_SPECIMEN[trial_id]
    _require(expected is not None, "SS-U0 has no attributable payload specimen")
    marker_records = _load_json_lines(trial / "markers.jsonl", "marker log")
    _validate_marker_records(trial_id, marker_records)
    marker_names = [record["marker"] for record in marker_records]
    _require("FILE_SELECTED" in marker_names, "file selection gate is missing")
    _require("SET_IMAGE_CLICKED" in marker_names, "explicit commit marker is missing")
    _require("DEVICE_OUTCOME_OBSERVED" not in marker_names, "workflow is already closed")
    authorization = _read_authorization(trial, workspace, trial_id, expected)
    records, sequence = _next_record_sequence(trial / "payload-captures.jsonl", "payload log")
    _validate_payload_records(trial, authorization, records)
    _require(sequence <= MAX_EVENTS, "payload event limit reached")
    if records:
        _require(current_time >= records[-1]["time_monotonic_ns"], "payload time moved backwards")
    retained_payload_bytes = sum(int(record["payload_bytes"]) for record in records)
    _require(retained_payload_bytes + len(payload) <= MAX_TOTAL_PAYLOAD_BYTES, "payload storage limit reached")
    filename = f"payload-{sequence:06d}-{direction}-{_command_text(command)[2:]}.bin"
    payload_path = trial / "payloads" / filename
    _exclusive_write(payload_path, payload)
    payload_digest = hashlib.sha256(payload).hexdigest()
    event = {
        "attribution_marker": "FILE_SELECTED+SET_IMAGE_CLICKED",
        "attribution_selected_monotonic_ns": authorization["selected_monotonic_ns"],
        "attribution_selected_sequence": authorization["selected_sequence"],
        "attribution_selection_sha256": authorization["selection_sha256"],
        "attribution_specimen": authorization["specimen"],
        "attribution_fixture_sha256": authorization["fixture_sha256"],
        "auto_continue": False,
        "call_origin": call_origin,
        "capture_name": filename,
        "classification": "captured-bytes",
        "command": _command_text(command),
        "declared_length": declared_length,
        "direction": direction,
        "payload_bytes": len(payload),
        "payload_sha256": payload_digest,
        "sequence": sequence,
        "time_monotonic_ns": current_time,
    }
    try:
        _append_json_line(trial / "payload-captures.jsonl", event, "payload log")
    except Exception:
        try:
            payload_path.unlink()
        except OSError:
            pass
        raise
    return event


def _value_from_register(frame: Any, register_name: str) -> int:
    register = frame.FindRegister(register_name)
    _require(register.IsValid(), f"required register {register_name} is unavailable")
    value = register.GetValueAsUnsigned()
    return int(value)


def _frame_origin(frame: Any, fallback: str) -> str:
    try:
        frame_name = frame.GetFunctionName()
    except Exception:
        frame_name = None
    boundary_name = str(frame_name) if frame_name else fallback
    try:
        thread = frame.GetThread()
        frame_count = min(int(thread.GetNumFrames()), MAX_BACKTRACE_FRAMES)
        for index in range(frame_count):
            candidate = thread.GetFrameAtIndex(index).GetFunctionName()
            if not candidate or str(candidate) == boundary_name:
                continue
            try:
                return _validate_call_origin(str(candidate))
            except Refusal:
                continue
    except Exception:
        pass
    try:
        return _validate_call_origin(boundary_name)
    except Refusal:
        return fallback


def _read_process_memory(frame: Any, address: int, count: int) -> bytes:
    _validate_declared_length(count)
    _require(count > 0, "memory read requires a non-empty declared length")
    process = frame.GetThread().GetProcess()
    error = _lldb.SBError()
    data = process.ReadMemory(address, count, error)
    _require(error.Success(), f"bounded memory read failed: {error.GetCString()}")
    _require(len(data) == count, "bounded memory read returned an unexpected length")
    return bytes(data)


def _outbound_values(frame: Any) -> Tuple[Tuple[int, int], int, int]:
    command = (_value_from_register(frame, "w1") & 0xFF, _value_from_register(frame, "w2") & 0xFF)
    pointer = _value_from_register(frame, "x3")
    declared_length = _validate_declared_length(_value_from_register(frame, "x4"))
    return command, pointer, declared_length


def _inbound_values(frame: Any) -> Tuple[Tuple[int, int], int, int]:
    frame_pointer = _value_from_register(frame, "x1")
    header = _read_process_memory(frame, frame_pointer, 16)
    command = (header[2], header[3])
    declared_length = _validate_declared_length(struct.unpack("<I", header[4:8])[0])
    payload_pointer = struct.unpack("<Q", header[8:16])[0]
    return command, payload_pointer, declared_length


def _callback_config(bp_loc: Any) -> Tuple[str, Path, Optional[str]]:
    breakpoint = bp_loc.GetBreakpoint()
    config = _ACTIVE_CALLBACKS.get(breakpoint.GetID())
    _require(config is not None, "callback configuration is missing")
    return config


_ACTIVE_CALLBACKS: Dict[int, Tuple[str, Path, Optional[str]]] = {}


def _chronology_callback(frame: Any, bp_loc: Any, internal_dict: Dict[str, Any]) -> bool:
    try:
        boundary, trial, _ = _callback_config(bp_loc)
        if boundary == "outbound":
            command, _, declared_length = _outbound_values(frame)
        else:
            command, _, declared_length = _inbound_values(frame)
        record_chronology_event(
            trial,
            "outbound" if boundary == "outbound" else "inbound",
            command,
            declared_length,
            _frame_origin(frame, "sendDataToDeck" if boundary == "outbound" else "OnDeckFrameReceived"),
        )
        return False
    except Exception as error:
        internal_dict["hidhogg_screensaver_error"] = str(error)
        return True


def _payload_callback(frame: Any, bp_loc: Any, internal_dict: Dict[str, Any]) -> bool:
    try:
        boundary, trial, specimen = _callback_config(bp_loc)
        _require(boundary == "outbound" and specimen in ("A", "B"), "payload callback boundary or specimen is invalid")
        command, pointer, declared_length = _outbound_values(frame)
        _require(declared_length > 0, "payload callback requires a non-empty declared length")
        payload = _read_process_memory(frame, pointer, declared_length)
        record_payload_event(trial, "outbound", command, declared_length, _frame_origin(frame, "sendDataToDeck"), payload)
    except Exception as error:
        internal_dict["hidhogg_screensaver_error"] = str(error)
    return True


def _set_callback(
    bp: Any,
    callback: str,
    mode: str,
    boundary: str,
    trial: Path,
    specimen: Optional[str] = None,
) -> None:
    _require(bp.IsValid(), "unable to create application-boundary breakpoint")
    _require(bp.GetNumLocations() > 0, "application-boundary breakpoint has no resolved locations")
    bp.SetScriptCallbackFunction(callback)
    if hasattr(bp, "SetAutoContinue"):
        if mode == "chronology":
            bp.SetAutoContinue(True)
        else:
            bp.SetAutoContinue(False)
    _ACTIVE_CALLBACKS[bp.GetID()] = (boundary, trial, specimen)


def _install_callbacks(debugger: Any, trial: Path, mode: str, specimen: Optional[str]) -> str:
    _require(_lldb is not None, "LLDB Python runtime is required only when the owner starts a reviewed session")
    if mode == "chronology":
        validate_trial(trial, require_prepared=True)
    else:
        workspace, trial_id = validate_trial(trial, require_prepared=True)
        _require_specimen_gate(trial_id, specimen)
        _read_authorization(trial, workspace, trial_id, specimen or "")
    target = debugger.GetSelectedTarget()
    _require(target.IsValid(), "LLDB target is not selected")
    outbound = target.BreakpointCreateByName("sendDataToDeck")
    if not outbound.IsValid() or outbound.GetNumLocations() == 0:
        outbound = target.BreakpointCreateByAddress(0x100030184)
    if mode == "chronology":
        inbound = target.BreakpointCreateByName("OnDeckFrameReceived")
        if not inbound.IsValid() or inbound.GetNumLocations() == 0:
            inbound = target.BreakpointCreateByAddress(0x100513CBC)
        _set_callback(outbound, "screensaver_capture._chronology_callback", mode, "outbound", trial)
        _set_callback(inbound, "screensaver_capture._chronology_callback", mode, "inbound", trial)
        return "chronology callbacks installed; application remains stopped until the owner continues it"
    _set_callback(outbound, "screensaver_capture._payload_callback", mode, "outbound", trial, specimen)
    return "stopped-payload callback installed; each attributable stop remains stopped"


def hidhogg_screensaver_chronology(debugger: Any, command: str, result: Any, internal_dict: Dict[str, Any]) -> None:
    try:
        arguments = argparse.ArgumentParser(prog="hidhogg-screensaver-chronology", add_help=False)
        arguments.add_argument("--trial-dir", required=True)
        parsed = arguments.parse_args(command.split())
        result.PutCString(_install_callbacks(debugger, Path(parsed.trial_dir), "chronology", None))
    except SystemExit as error:
        result.SetError(f"invalid chronology command: {error}")
    except Exception as error:
        result.SetError(str(error))


def hidhogg_screensaver_payload(debugger: Any, command: str, result: Any, internal_dict: Dict[str, Any]) -> None:
    try:
        arguments = argparse.ArgumentParser(prog="hidhogg-screensaver-payload", add_help=False)
        arguments.add_argument("--trial-dir", required=True)
        arguments.add_argument("--specimen", required=True)
        parsed = arguments.parse_args(command.split())
        result.PutCString(_install_callbacks(debugger, Path(parsed.trial_dir), "payload", parsed.specimen))
    except SystemExit as error:
        result.SetError(f"invalid payload command: {error}")
    except Exception as error:
        result.SetError(str(error))


def _handle_create_workspace(arguments: Any) -> Dict[str, Any]:
    return _fixture_summary(create_workspace())


def _handle_generate_fixtures(arguments: Any) -> Dict[str, Any]:
    return _fixture_summary(generate_fixtures(Path(arguments.workspace)))


def _handle_verify_fixtures(arguments: Any) -> Dict[str, Any]:
    return _fixture_summary(Path(arguments.workspace))


def _handle_prepare_capture(arguments: Any) -> Dict[str, str]:
    return prepare_capture(Path(arguments.trial_dir), arguments.specimen)


def _handle_mark_action(arguments: Any) -> Dict[str, Any]:
    return mark_action(
        Path(arguments.trial_dir),
        arguments.marker,
        arguments.specimen,
        arguments.outcome,
        arguments.arm_payload,
    )


def _handle_arm_payload(arguments: Any) -> Dict[str, bool]:
    return arm_payload(Path(arguments.trial_dir), arguments.specimen)


def _handle_record_chronology(arguments: Any) -> Dict[str, Any]:
    return record_chronology_event(
        Path(arguments.trial_dir),
        arguments.direction,
        _parse_command(arguments.command),
        arguments.declared_length,
        arguments.call_origin,
        arguments.time_ns,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    create = subparsers.add_parser("create-workspace")
    create.set_defaults(handler=_handle_create_workspace)
    fixtures = subparsers.add_parser("generate-fixtures")
    fixtures.add_argument("--workspace", required=True)
    fixtures.set_defaults(handler=_handle_generate_fixtures)
    verify = subparsers.add_parser("verify-fixtures")
    verify.add_argument("--workspace", required=True)
    verify.set_defaults(handler=_handle_verify_fixtures)
    prepare = subparsers.add_parser("prepare-capture")
    prepare.add_argument("--trial-dir", required=True)
    prepare.add_argument("--specimen")
    prepare.set_defaults(handler=_handle_prepare_capture)
    mark = subparsers.add_parser("mark-action")
    mark.add_argument("--trial-dir", required=True)
    mark.add_argument("--marker", required=True)
    mark.add_argument("--specimen")
    mark.add_argument("--outcome")
    mark.add_argument("--arm-payload", action="store_true")
    mark.set_defaults(handler=_handle_mark_action)
    arm = subparsers.add_parser("arm-payload")
    arm.add_argument("--trial-dir", required=True)
    arm.add_argument("--specimen", required=True)
    arm.set_defaults(handler=_handle_arm_payload)
    chronology = subparsers.add_parser("record-chronology")
    chronology.add_argument("--trial-dir", required=True)
    chronology.add_argument("--direction", required=True)
    chronology.add_argument("--command", required=True)
    chronology.add_argument("--declared-length", required=True, type=int)
    chronology.add_argument("--call-origin", required=True)
    chronology.add_argument("--time-ns", type=int)
    chronology.set_defaults(handler=_handle_record_chronology)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = _parser()
    try:
        arguments = parser.parse_args(argv)
        result = arguments.handler(arguments)
        if result is not None:
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except Refusal as error:
        print(f"refusing screensaver operation: {error}", file=sys.stderr)
        return 65
    except (OSError, ValueError, TypeError) as error:
        print(f"screensaver operation failed: {error}", file=sys.stderr)
        return 74


if _lldb is not None:
    _lldb.debugger.HandleCommand("command script add -f screensaver_capture.hidhogg_screensaver_chronology hidhogg-screensaver-chronology")
    _lldb.debugger.HandleCommand("command script add -f screensaver_capture.hidhogg_screensaver_payload hidhogg-screensaver-payload")


if __name__ == "__main__":
    raise SystemExit(main())
