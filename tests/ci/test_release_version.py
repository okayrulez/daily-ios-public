import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseVersionTests(unittest.TestCase):
    def check(self, version, build="94", project_marker=False, firebase_file=None,
              widget_build="94", embed_widget=True):
        with tempfile.TemporaryDirectory() as directory:
            ipa = pathlib.Path(directory) / "DailyX.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                info = {
                    "CFBundleIdentifier": "com.okayrulez.daily",
                    "CFBundleShortVersionString": version, "CFBundleVersion": build,
                }
                if project_marker:
                    info["DailyPersonalProjectID"] = "fixture"
                archive.writestr("Payload/DailyX.app/Info.plist", plistlib.dumps(info))
                if embed_widget:
                    widget = {
                        "CFBundleIdentifier": "com.okayrulez.daily.widgets",
                        "CFBundleShortVersionString": version,
                        "CFBundleVersion": widget_build,
                        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
                    }
                    archive.writestr("Payload/DailyX.app/PlugIns/DailyWidgets.appex/Info.plist", plistlib.dumps(widget))
                if firebase_file:
                    archive.writestr("Payload/DailyX.app/" + firebase_file, plistlib.dumps({}))
            return subprocess.run([sys.executable, str(ROOT / "scripts/verify-release-version.py"),
                                   str(ipa), "1.0.1", "94"], capture_output=True, text=True)

    def test_rejects_closed_train_even_when_build_number_is_new(self):
        result = self.check("1.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected 1.0.1", result.stderr)

    def test_accepts_matching_release_and_build(self):
        result = self.check("1.0.1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_widget(self):
        result = self.check("1.0.1", embed_widget=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DailyWidgets", result.stderr)

    def test_rejects_widget_with_stale_build_number(self):
        result = self.check("1.0.1", widget_build="93")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DailyWidgets", result.stderr)

    def test_rejects_stale_build_number(self):
        self.assertEqual(self.check("1.0.1", "93").returncode, 1)

    def test_rejects_developer_firebase_configuration(self):
        for options in [{"project_marker": True}, {"firebase_file": "BundledFirebase.plist"},
                        {"firebase_file": "GoogleService-Info.plist"}]:
            with self.subTest(options=options):
                result = self.check("1.0.1", **options)
                self.assertEqual(result.returncode, 1)
                self.assertIn("developer Firebase configuration", result.stderr)

    def test_xcodegen_app_plist_uses_marketing_setting(self):
        project = (ROOT / "ios/project.yml").read_text(encoding="utf-8")
        self.assertIn("CFBundleShortVersionString: $(MARKETING_VERSION)", project)


if __name__ == "__main__":
    unittest.main()
