# dAIly for iOS

dAIly is a SwiftUI journal and agenda app. It organizes entries into mind maps, offers a daily reflection, and lets you confirm actions for Apple Calendar, Reminders, and iPhone alarms. It can store your entries on your device. Firebase sync is optional.

This repository contains the iOS source snapshot for dAIly 1.1.1, including its TypeScript analysis module and tests.

## Run the project

Install Xcode with the iOS SDK that includes AlarmKit, an iPhone simulator, XcodeGen, and Node.js 24. Run the verification script from the repository root.

```bash
bash scripts/verify-ios.sh
```

The script generates the Xcode project at ios/DailyX.xcodeproj and runs the tests. In Xcode, use the DailyX scheme to run the app and DailyX-CI to run the iOS tests. The TypeScript checks also run independently via npm ci and npm run verify.

## Configure optional services

- For Google sign-in, configure an iOS OAuth client for your app identifier. Set DAILY_GOOGLE_OAUTH_CLIENT_ID and DAILY_GOOGLE_URL_SCHEME (the reversed client ID) in the DailyXApp build settings in ios/project.yml before generating the project.
- For Firebase integration, use your own Firebase project. This repository includes Firestore rules and an example environment file for the optional push worker.
- For physical devices, use your own Apple signing team, bundle identifiers, and matching App Group configuration. iPhone alarms require iOS 26 or later and the user's permission.

See [Google and local storage](ios/LOCAL-FIRST-GOOGLE.md) and [account sign-in](ios/SIGN_IN.md) for implementation details.
