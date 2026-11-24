# Device storage and optional Google/Firebase sync

The normal setup no longer asks for GoogleService-Info.plist. A new installation can start on the device without configuring Firebase. Own ChatGPT sign-in and an internet connection are still needed for inference.

## Storage and publication

- `DeviceWorkspaceStore` is the protected, atomic primary record store, isolated by SHA-256(projectID + newline + UID). Journals, answers, agenda cards, map pages, the memory manifest and its chunks persist together. Drafts keep their previous per-project location so an upgrade does not abandon unsent edits.
- Firebase is an optional publication target. Local commits are acknowledged after the device write; cloud failures are displayed separately and retain a durable, ordered outbox.
- Publication checks previous hashes in a transaction and stores a stable receipt. Retrying an upload whose acknowledgement was lost does not apply it twice. Large journals use the existing chunk transport without truncation; initial transfers are split by document count and byte size.
- Opening tabs, resuming the app and reopening maps do not read the cloud. Before an AI run, configured sync checks the revision marker and memory manifest; it downloads the workspace only when those change. Manual refresh remains explicit. The five-journal AI map quality review is independent of persistence/sync.
- A conflicting cloud version does not replace local changes. An explicit recovery action first preserves the whole local workspace and its versions as a separate device workspace, then opens the cloud snapshot. Device workspaces remain available under setup settings.
- A local-only workspace does not attempt APNs server registration. Local reminders continue to use the normal permission and scheduling path. A newly created Firebase project does not magically include a push worker; automatic remote registration requires a configured service.

## Google connection

The bundled public OAuth iOS client identity and URL callback identify dAIly. They do not select a developer database, contain an API secret or authenticate the developer. No bundled Firebase project is configured for a new user. A legacy configuration file without an explicit storage-mode choice is not silently activated on upgrade; it remains available through the advanced restore action. Previously selected Google / explicit legacy connections restore normally.

After an explicit Google sign-in, users select a Firebase project they can access or choose to create one in their own Google account. Creation uses Cloud Resource Manager, Firebase Management, Service Usage and Firestore APIs. It does not attach a billing account, delete projects or install service-account keys. A persisted candidate project ID allows setup retries to continue rather than create another project after a timeout. Existing populated workspaces are not automatically merged with a device-only workspace; opt-in transfer applies to an empty target.

Google OAuth uses the `cloud-platform` scope because creating projects and accessing Firestore as a project owner require Cloud IAM permissions. Firestore REST OAuth calls are authorized by Google IAM. The app restricts record requests to the selected project/user subtree and binds each transport to the Google account that selected it. Existing Firebase Authentication UIDs are looked up for the signed-in email before opening existing data. A create-once `dailyXGoogleAccounts/{sha256(googleUID)}` binding in the selected project keeps that workspace UID stable if Firebase Authentication is enabled later. New OAuth-only projects use the Google UID; desktop/other clients connecting to such a project must use that binding as well, rather than assuming a newly created Firebase Auth UID will expose the same records. The advanced developer Firebase SDK configuration path remains available for existing installations.

Official implementation references:

- https://developers.google.com/identity/sign-in/ios/api-access
- https://firebase.google.com/docs/firestore/use-rest-api
- https://firebase.google.com/docs/projects/api/workflow_set-up-and-manage-project
- https://firebase.google.com/docs/reference/firebase-management/rest/v1beta1/projects/addFirebase
- https://firebase.google.com/docs/firestore/reference/rest/v1/projects.databases/create

## Validation limits and device checks

Windows checks do not compile Swift or establish a real Google OAuth session. The native tests added here cover device persistence, restart, publication order, lost acknowledgement, immutable chunk collisions, project/account isolation, long journals, explicit conflict recovery and the optional tutorial step. Execute them with the Xcode CI scheme on macOS.

Before calling Google onboarding production-verified, use TestFlight to check the public client's callback, consent-screen publishing/verification, granted Cloud scope and API availability. Google may require account/project setup or reject a managed account, consent request, project creation quota or permission. These failures must remain visible in the setup status; the app must keep local use available and must never show a fake successful connection.

Device acceptance sequence:

1. Fresh install: start locally, write/save, restart, and verify the journal and maps persist without Firebase configuration.
2. Connect own ChatGPT and run one journal analysis; check generated questions, agenda, export and local notification scheduling.
3. Use Google to connect an existing personal Firebase project; verify the expected existing Firebase UID and records, then switch accounts and verify isolation.
4. Explicitly create a new personal project and opt into transfer from a populated device workspace. Check project/database creation, record transfer and interruption/resume.
5. Save while offline in a cloud-linked workspace, restart offline, reconnect and verify one publication of each change. Edit the same source remotely and confirm conflict recovery preserves a separate local copy.
6. Verify opening other tabs makes no remote reads; trigger another AI run to check changed remote memory is fetched once.

This change does not submit an App Review, run a Codemagic build, change Google consent settings, create a real project during development, or update the installed desktop package.
