"""Reuse dAIly's public Firebase configuration for its DailyX update build."""
import base64
import os
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[1]
encoded = os.environ.get("DAILYX_FIREBASE_PLIST_BASE64")
if encoded:
    raw = base64.b64decode(encoded, validate=True)
else:
    # Same installed app identity: keep the existing owner-project configuration.
    existing = root.parent / "ios/DailyApp/BundledFirebase.plist"
    if not existing.is_file():
        raise SystemExit("Existing dAIly Firebase plist is missing; provide DAILYX_FIREBASE_PLIST_BASE64")
    raw = existing.read_bytes()
if len(raw) > 65536:
    raise SystemExit("Firebase client configuration exceeds the allowed size")
config = plistlib.loads(raw)
if config.get("BUNDLE_ID") != "com.okayrulez.daily" or "private_key" in config:
    raise SystemExit("Use the existing public Firebase plist registered for com.okayrulez.daily")
if not re.fullmatch(r"[a-z][a-z0-9-]{3,62}", config.get("PROJECT_ID", "")):
    raise SystemExit("Invalid Firebase project identity")
allowed = ["PROJECT_ID", "GOOGLE_APP_ID", "API_KEY", "BUNDLE_ID", "GCM_SENDER_ID",
           "PLIST_VERSION", "CLIENT_ID", "REVERSED_CLIENT_ID"]
safe = {key: config[key] for key in allowed if key in config}
if sys.argv[1:] == ["stamp"]:
    path = root / "ios/DailyApp/Info.generated.plist"
    info = plistlib.loads(path.read_bytes())
    info["DailyPersonalProjectID"] = config["PROJECT_ID"]
    path.write_bytes(plistlib.dumps(info))
else:
    (root / "ios/DailyApp/BundledFirebase.plist").write_bytes(plistlib.dumps(safe))
    scheme = safe.get("REVERSED_CLIENT_ID")
    if scheme:
        if not re.fullmatch(r"[A-Za-z0-9.-]+", scheme):
            raise SystemExit("Invalid Google callback scheme")
        path = root / "ios/project.yml"
        path.write_text(path.read_text().replace("dailyx-google-unconfigured", scheme))
