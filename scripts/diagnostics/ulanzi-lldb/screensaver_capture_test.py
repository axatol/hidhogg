#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import shutil
import stat
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("screensaver_capture.py")
MODULE_SPEC = importlib.util.spec_from_file_location("screensaver_capture", MODULE_PATH)
assert MODULE_SPEC is not None and MODULE_SPEC.loader is not None
screensaver_capture = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(screensaver_capture)


class ScreensaverCaptureTest(unittest.TestCase):
    def setUp(self):
        self.workspace = screensaver_capture.create_workspace()

    def tearDown(self):
        if self.workspace.exists():
            shutil.rmtree(self.workspace)

    def trial(self, trial_id):
        return self.workspace / trial_id

    def prepare(self, trial_id, specimen=None):
        return screensaver_capture.prepare_capture(self.trial(trial_id), specimen)

    def mark(self, trial_id, marker, specimen=None, outcome=None, arm_payload=False):
        return screensaver_capture.mark_action(
            self.trial(trial_id), marker, specimen, outcome, arm_payload
        )

    def select_and_commit(self, trial_id, specimen):
        self.mark(trial_id, "CLICK_SCREEN_SAVER")
        self.mark(trial_id, "EDITOR_VISIBLE")
        self.mark(trial_id, "PICKER_VISIBLE")
        self.mark(trial_id, "FILE_SELECTED", specimen, arm_payload=True)
        self.mark(trial_id, "EDITOR_VISIBLE")
        self.mark(trial_id, "SET_IMAGE_CLICKED")

    @staticmethod
    def rewrite_jsonl(path, records):
        path.write_text(
            "".join(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n" for record in records),
            encoding="utf-8",
        )

    def test_workspace_and_fixture_contract(self):
        self.assertEqual(stat.S_IMODE(self.workspace.stat().st_mode), 0o700)
        manifest = screensaver_capture.verify_fixtures(self.workspace)
        self.assertEqual(set(manifest["fixtures"]), {"A", "B"})
        digests = []
        for specimen in ("A", "B"):
            path = self.workspace / "specimens" / f"screensaver-{specimen}.png"
            data = path.read_bytes()
            width, height, metadata_free = screensaver_capture.inspect_png(data)
            self.assertEqual((width, height), (1220, 708))
            self.assertTrue(metadata_free)
            digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(digest, screensaver_capture.EXPECTED_FIXTURE_SHA256[specimen])
            digests.append(digest)
        self.assertNotEqual(digests[0], digests[1])
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.generate_fixtures(self.workspace)

    def test_capture_preparation_requires_expected_specimen_and_refuses_overwrite(self):
        with self.assertRaises(screensaver_capture.Refusal):
            self.prepare("SS-U1")
        with self.assertRaises(screensaver_capture.Refusal):
            self.prepare("SS-U1", "B")
        result = self.prepare("SS-U1", "A")
        self.assertEqual(result["specimen"], "A")
        self.assertEqual((self.trial("SS-U1") / "payloads").stat().st_mode & 0o777, 0o700)
        chronology = (self.trial("SS-U1") / "chronology.lldb").read_text()
        payload = (self.trial("SS-U1") / "payload.lldb").read_text()
        self.assertIn("hidhogg-screensaver-chronology", chronology)
        self.assertIn("hidhogg-screensaver-payload", payload)
        forbidden_commands = ("process " + "launch", "process " + "attach")
        for forbidden_command in forbidden_commands:
            self.assertNotIn(forbidden_command, chronology.lower())
            self.assertNotIn(forbidden_command, payload.lower())
        with self.assertRaises(screensaver_capture.Refusal):
            self.prepare("SS-U1", "A")

    def test_marker_workflow_is_closed_and_payload_is_explicitly_attributable(self):
        self.prepare("SS-U1", "A")
        with self.assertRaises(screensaver_capture.Refusal):
            self.mark("SS-U1", "EDITOR_VISIBLE")
        self.mark("SS-U1", "CLICK_SCREEN_SAVER")
        self.mark("SS-U1", "EDITOR_VISIBLE")
        self.mark("SS-U1", "PICKER_VISIBLE")
        with self.assertRaises(screensaver_capture.Refusal):
            self.mark("SS-U1", "FILE_SELECTED")
        self.mark("SS-U1", "FILE_SELECTED", "A", arm_payload=True)
        self.mark("SS-U1", "EDITOR_VISIBLE")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc"
            )
        self.mark("SS-U1", "SET_IMAGE_CLICKED")
        event = screensaver_capture.record_payload_event(
            self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc"
        )
        self.assertFalse(event["auto_continue"])
        self.assertEqual(event["attribution_specimen"], "A")
        self.assertTrue((self.trial("SS-U1") / "payloads" / event["capture_name"]).is_file())
        self.mark("SS-U1", "EDITOR_CLOSED")
        self.mark("SS-U1", "DEVICE_OUTCOME_OBSERVED", outcome="A")
        screensaver_capture.validate_prepared_capture(self.trial("SS-U1"))
        with self.assertRaises(screensaver_capture.Refusal):
            self.mark("SS-U1", "CLICK_SCREEN_SAVER")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"def"
            )
        markers = [
            json.loads(line)
            for line in (self.trial("SS-U1") / "markers.jsonl").read_text().splitlines()
        ]
        self.assertEqual(
            [record["marker"] for record in markers],
            [
                "CLICK_SCREEN_SAVER",
                "EDITOR_VISIBLE",
                "PICKER_VISIBLE",
                "FILE_SELECTED",
                "EDITOR_VISIBLE",
                "SET_IMAGE_CLICKED",
                "EDITOR_CLOSED",
                "DEVICE_OUTCOME_OBSERVED",
            ],
        )

    def test_marker_time_must_be_a_non_decreasing_integer(self):
        records = [
            {"marker": "CLICK_SCREEN_SAVER", "monotonic_ns": 10, "sequence": 1},
            {"marker": "EDITOR_VISIBLE", "monotonic_ns": 9, "sequence": 2},
        ]
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture._validate_marker_records("SS-U0", records)
        records[1]["monotonic_ns"] = True
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture._validate_marker_records("SS-U0", records)

    def test_mark_action_rejects_invalid_generated_time_before_append(self):
        self.prepare("SS-U0")
        with patch.object(screensaver_capture.time, "monotonic_ns", return_value=True):
            with self.assertRaises(screensaver_capture.Refusal):
                self.mark("SS-U0", "CLICK_SCREEN_SAVER")
        self.assertEqual((self.trial("SS-U0") / "markers.jsonl").read_text(), "")
        with patch.object(screensaver_capture.time, "monotonic_ns", return_value=50):
            self.mark("SS-U0", "CLICK_SCREEN_SAVER")
        with patch.object(screensaver_capture.time, "monotonic_ns", return_value=49):
            with self.assertRaises(screensaver_capture.Refusal):
                self.mark("SS-U0", "EDITOR_VISIBLE")
        self.assertEqual(len((self.trial("SS-U0") / "markers.jsonl").read_text().splitlines()), 1)
    def test_payload_time_must_be_a_non_decreasing_integer(self):
        self.prepare("SS-U1", "A")
        self.select_and_commit("SS-U1", "A")
        screensaver_capture.record_payload_event(
            self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
        )
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U1"), "outbound", (0, 14), 3, "sendDataToDeck", b"def", 99
            )
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U1"), "outbound", (0, 14), 3, "sendDataToDeck", b"def", True
            )

    def test_selection_binding_rejects_mutated_marker_and_authorization(self):
        self.prepare("SS-U1", "A")
        self.mark("SS-U1", "CLICK_SCREEN_SAVER")
        self.mark("SS-U1", "EDITOR_VISIBLE")
        self.mark("SS-U1", "PICKER_VISIBLE")
        self.mark("SS-U1", "FILE_SELECTED", "A", arm_payload=True)
        marker_path = self.trial("SS-U1") / "markers.jsonl"
        markers = [json.loads(line) for line in marker_path.read_text().splitlines()]
        markers[3]["monotonic_ns"] += 1
        self.rewrite_jsonl(marker_path, markers)
        self.mark("SS-U1", "EDITOR_VISIBLE")
        self.mark("SS-U1", "SET_IMAGE_CLICKED")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
            )

        self.prepare("SS-U2", "B")
        self.select_and_commit("SS-U2", "B")
        authorization_path = self.trial("SS-U2") / "payload-authorization.json"
        authorization = json.loads(authorization_path.read_text())
        authorization["selected_monotonic_ns"] += 1
        self.rewrite_jsonl(authorization_path, [authorization])
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U2"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
            )

    def test_payload_rows_require_authorized_attribution(self):
        self.prepare("SS-U1", "A")
        self.select_and_commit("SS-U1", "A")
        event = screensaver_capture.record_payload_event(
            self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
        )
        payload_log = self.trial("SS-U1") / "payload-captures.jsonl"
        row = json.loads(payload_log.read_text())
        row["attribution_specimen"] = "B"
        self.rewrite_jsonl(payload_log, [row])
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.validate_prepared_capture(self.trial("SS-U1"))
        self.assertEqual(event["capture_name"], row["capture_name"])

        self.prepare("SS-U2", "B")
        self.select_and_commit("SS-U2", "B")
        screensaver_capture.record_payload_event(
            self.trial("SS-U2"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
        )
        payload_log = self.trial("SS-U2") / "payload-captures.jsonl"
        row = json.loads(payload_log.read_text())
        row["attribution_fixture_sha256"] = "0" * 64
        self.rewrite_jsonl(payload_log, [row])
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.validate_prepared_capture(self.trial("SS-U2"))

    def test_payload_rows_and_artifacts_must_match_size_hash_and_names(self):
        self.prepare("SS-U1", "A")
        self.select_and_commit("SS-U1", "A")
        event = screensaver_capture.record_payload_event(
            self.trial("SS-U1"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
        )
        payload_path = self.trial("SS-U1") / "payloads" / event["capture_name"]
        payload_path.write_bytes(b"abd")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.validate_prepared_capture(self.trial("SS-U1"))
        payload_path.write_bytes(b"abcd")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.validate_prepared_capture(self.trial("SS-U1"))

        self.prepare("SS-U2", "B")
        self.select_and_commit("SS-U2", "B")
        event = screensaver_capture.record_payload_event(
            self.trial("SS-U2"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
        )
        payload_path = self.trial("SS-U2") / "payloads" / event["capture_name"]
        payload_path.unlink()
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.validate_prepared_capture(self.trial("SS-U2"))

        self.prepare("SS-U3", "A")
        self.select_and_commit("SS-U3", "A")
        screensaver_capture.record_payload_event(
            self.trial("SS-U3"), "outbound", (0, 13), 3, "sendDataToDeck", b"abc", 100
        )
        orphan = self.trial("SS-U3") / "payloads" / "payload-000002-outbound-000e.bin"
        orphan.write_bytes(b"orphan")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.validate_prepared_capture(self.trial("SS-U3"))

    def test_payload_callback_rejects_invalid_length_before_memory_read(self):
        class Register:
            def __init__(self, value):
                self.value = value

            def IsValid(self):
                return True

            def GetValueAsUnsigned(self):
                return self.value

        class Process:
            def __init__(self):
                self.reads = 0

            def ReadMemory(self, address, count, error):
                self.reads += 1
                raise AssertionError("ReadMemory must not run for an invalid declared length")

        class Thread:
            def __init__(self, process):
                self.process = process

            def GetProcess(self):
                return self.process

        class Frame:
            def __init__(self, process, declared_length):
                self.process = process
                self.registers = {"w1": 0, "w2": 13, "x3": 4096, "x4": declared_length}

            def FindRegister(self, name):
                return Register(self.registers[name])

            def GetThread(self):
                return Thread(self.process)

        class Breakpoint:
            def GetID(self):
                return 991

        class Location:
            def GetBreakpoint(self):
                return Breakpoint()

        self.prepare("SS-U1", "A")
        location = Location()
        screensaver_capture._ACTIVE_CALLBACKS[991] = ("outbound", self.trial("SS-U1"), "A")
        try:
            for declared_length in (0, screensaver_capture.MAX_DECLARED_LENGTH + 1):
                process = Process()
                internal = {}
                self.assertTrue(
                    screensaver_capture._payload_callback(
                        Frame(process, declared_length), location, internal
                    )
                )
                self.assertEqual(process.reads, 0)
                self.assertIn("hidhogg_screensaver_error", internal)
        finally:
            screensaver_capture._ACTIVE_CALLBACKS.pop(991, None)

    def test_chronology_is_metadata_only_and_bounded(self):
        self.prepare("SS-U0")
        first = screensaver_capture.record_chronology_event(
            self.trial("SS-U0"), "outbound", (0, 3), 0, "sendDataToDeck", 100
        )
        second = screensaver_capture.record_chronology_event(
            self.trial("SS-U0"), "inbound", (3, 3), 1014, "OnDeckFrameReceived", 101
        )
        self.assertNotEqual(first["capture_name"], second["capture_name"])
        self.assertFalse(first["payload_captured"])
        self.assertEqual(first["classification"], "observed-chronology")
        self.assertEqual(first["direction"], "outbound")
        self.assertEqual(second["direction"], "inbound")
        self.assertEqual((self.trial("SS-U0") / "payload-captures.jsonl").read_text(), "")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_chronology_event(
                self.trial("SS-U0"), "outbound", (0, 3), screensaver_capture.MAX_DECLARED_LENGTH + 1, "sendDataToDeck", 102
            )
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_chronology_event(
                self.trial("SS-U0"), "outbound", (0, 3), 1, "/Users/identifier/sendDataToDeck", 102
            )
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_chronology_event(
                self.trial("SS-U0"), "outbound", (0, 3), 1, "sendDataToDeck", 99
            )
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_chronology_event(
                self.trial("SS-U0"), "outbound", (0, 3), 1, "sendDataToDeck", True
            )

    def test_u0_cancel_flow_requires_no_specimen(self):
        self.prepare("SS-U0")
        for marker in ("CLICK_SCREEN_SAVER", "EDITOR_VISIBLE", "CANCEL_CLICKED", "EDITOR_CLOSED"):
            self.mark("SS-U0", marker)
        self.mark("SS-U0", "DEVICE_OUTCOME_OBSERVED", outcome="UNCHANGED")
        with self.assertRaises(screensaver_capture.Refusal):
            screensaver_capture.record_payload_event(
                self.trial("SS-U0"), "outbound", (0, 13), 0, "sendDataToDeck", b""
            )


if __name__ == "__main__":
    unittest.main()
