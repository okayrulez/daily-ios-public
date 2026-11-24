"""Verify exported IPA metadata, rather than trusting Xcode build settings."""
import plistlib
import re
import sys
import zipfile


def main():
    if len(sys.argv) != 4:
        print("Usage: verify-release-version.py app.ipa expected-version expected-build", file=sys.stderr)
        return 2
    path, expected, build = sys.argv[1:]
    try:
        if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", expected):
            raise ValueError("Invalid expected marketing version")
        with zipfile.ZipFile(path) as archive:
            names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
            if len(names) != 1:
                raise ValueError("Expected exactly one app Info.plist")
            info = plistlib.loads(archive.read(names[0]))
            widget_plists = [name for name in archive.namelist() if re.fullmatch(
                re.escape(names[0].removesuffix("Info.plist")) + r"PlugIns/[^/]+\.appex/Info\.plist", name
            )]
            widgets = [plistlib.loads(archive.read(name)) for name in widget_plists]
            if "DailyPersonalProjectID" in info or any(
                name.rsplit("/", 1)[-1] in {"BundledFirebase.plist", "GoogleService-Info.plist"}
                for name in archive.namelist()
            ):
                raise ValueError("Distributed IPA must not include a developer Firebase configuration")
        if info.get("CFBundleIdentifier") != "com.okayrulez.daily":
            raise ValueError("Wrong app identity")
        actual = info.get("CFBundleShortVersionString")
        if actual != expected:
            raise ValueError(f"IPA marketing version {actual}; expected {expected}")
        if info.get("CFBundleVersion") != build:
            raise ValueError(f"IPA build {info.get('CFBundleVersion')}; expected {build}")
        widget = next((item for item in widgets if item.get("CFBundleIdentifier") == "com.okayrulez.daily.widgets"), None)
        if (widget is None or widget.get("CFBundleShortVersionString") != expected
                or widget.get("CFBundleVersion") != build
                or widget.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension"):
            raise ValueError("DailyWidgets extension missing or its version/build differs from DailyX")
        print(f"Verified exported dAIly IPA and widget: version {actual}, build {build}")
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
