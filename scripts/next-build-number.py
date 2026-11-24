"""Resolve the existing dAIly app and choose an unused ascending build number."""
import json
import os
import re
import subprocess
import sys

BUNDLE_ID = "com.okayrulez.daily"
# Apple's rejection log confirms that build 30 has already been uploaded.
KNOWN_UPLOADED_BUILD = 30


def query(*arguments):
    result = subprocess.run(
        ["app-store-connect", *arguments, "--json", "--no-color"],
        text=True, capture_output=True, check=True, timeout=120,
    )
    if not result.stdout.strip():
        raise ValueError("App Store Connect returned no data; refusing to guess a build number")
    return json.loads(result.stdout)


def resolve_app_id(apps):
    if not isinstance(apps, list):
        raise ValueError("Invalid App Store Connect app list")
    matches = [app for app in apps if app.get("attributes", {}).get("bundleId") == BUNDLE_ID]
    if len(matches) != 1 or not re.fullmatch(r"[0-9]+", str(matches[0].get("id", ""))):
        raise ValueError("Expected exactly one existing com.okayrulez.daily app")
    return str(matches[0]["id"])


def next_number(latest, project_count):
    if not isinstance(latest, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", latest):
        raise ValueError("Invalid latest Apple build number")
    if not re.fullmatch(r"[0-9]+", project_count):
        raise ValueError("Invalid PROJECT_BUILD_NUMBER")
    # Advancing the major part also handles an existing number such as 30.2.1.
    return max(int(latest.split(".")[0]) + 1, int(project_count), KNOWN_UPLOADED_BUILD + 1)


def main():
    app_id = resolve_app_id(query("apps", "list", "--bundle-id-identifier", BUNDLE_ID,
                                  "--strict-match-identifier"))
    latest = query("get-latest-testflight-build-number", app_id, "--platform", "IOS")
    number = next_number(latest, os.environ.get("PROJECT_BUILD_NUMBER", "0"))
    print(f"dAIly: latest TestFlight build {latest}; next build {number}", file=sys.stderr)
    print(number)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Do not echo CLI output: authentication failures may contain account details.
        print(f"Cannot resolve next App Store build number ({type(error).__name__}). "
              "Check the ESHOT_APP_STORE integration and retry.", file=sys.stderr)
        sys.exit(1)
