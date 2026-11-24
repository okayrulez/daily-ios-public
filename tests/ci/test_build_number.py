import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "build_number", Path(__file__).resolve().parents[2] / "scripts/next-build-number.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildNumberTests(unittest.TestCase):
    def test_existing_30_becomes_31_with_new_workflow(self):
        self.assertEqual(module.next_number("30", "4"), 31)

    def test_advances_latest_apple_number_and_respects_project_counter(self):
        self.assertEqual(module.next_number("58", "12"), 59)
        self.assertEqual(module.next_number("30", "72"), 72)
        self.assertEqual(module.next_number("30.2.1", "4"), 31)

    def test_known_uploaded_floor_survives_stale_remote_result(self):
        self.assertEqual(module.next_number("12", "4"), 31)

    def test_invalid_number_is_never_silently_replaced(self):
        for latest in (None, "", "unknown", "30\n31", "-2"):
            with self.assertRaises(ValueError):
                module.next_number(latest, "4")
        with self.assertRaises(ValueError):
            module.next_number("30", "invalid")

    def test_requires_exact_existing_app_identity(self):
        app = {"id": "1234", "attributes": {"bundleId": module.BUNDLE_ID}}
        extension = {"id": "9999", "attributes": {"bundleId": module.BUNDLE_ID + ".widget"}}
        self.assertEqual(module.resolve_app_id([app, extension]), "1234")
        for apps in ([], [extension], [app, app]):
            with self.assertRaises(ValueError):
                module.resolve_app_id(apps)

    def test_full_resolution_emits_only_number_on_stdout(self):
        results = [subprocess.CompletedProcess([], 0,
                   '[{"id":"1234","attributes":{"bundleId":"com.okayrulez.daily"}}]', ''),
                   subprocess.CompletedProcess([], 0, '"30"', '')]
        output = io.StringIO()
        with patch.object(module.subprocess, "run", side_effect=results) as run, \
             patch.dict(os.environ, {"PROJECT_BUILD_NUMBER": "4"}), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            module.main()
        self.assertEqual(output.getvalue(), "31\n")
        self.assertIn("--strict-match-identifier", run.call_args_list[0].args[0])
        self.assertEqual(run.call_args_list[1].args[0][1:3],
                         ["get-latest-testflight-build-number", "1234"])

    def test_apple_failure_or_empty_response_stops_numbering(self):
        with patch.object(module.subprocess, "run", side_effect=subprocess.CalledProcessError(1, [])):
            with self.assertRaises(subprocess.CalledProcessError):
                module.main()
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '', '')):
            with self.assertRaises(ValueError):
                module.query("get-latest-testflight-build-number", "1234")


if __name__ == "__main__":
    unittest.main()
