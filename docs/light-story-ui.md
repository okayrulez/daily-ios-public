# Active onboarding rehearsal

The tour now renders a local simulation at the same native tab, toolbar and card locations as the app. It uses the shared journal card, Daily logo, export card and real OrganicAtlas graph renderer. It does not instantiate a second authenticated workspace, change the user's navigation or write example records to Firebase.

The flow is action driven:

1. A synthetic journal text appears in the shared writing card.
2. The user taps the highlighted Daily logo. A simulated analysis sheet opens for approximately one second.
3. After the sheet dismisses, the tour opens a full-screen example map. Four nodes and three new red connections animate into view. The user can pan/pinch and tap a note.
4. A rounded, scrolling note window shows its summary, source and related notes.
5. The user chooses whether to add the example reminder. Advancing is disabled until a choice is made.
6. The agenda shows one plan, plus a reminder only when the user selected Yes.
7. The Settings export card opens a sample context document, followed by account ownership guidance and the optional existing social profile form.

Spotlight rectangles use measured global frames, not hardcoded screen coordinates. A separate registry redraws only the mask and connector when geometry changes. The native simulated tabs and controls do not inherit coach text transitions. Motion is finite and Reduced Motion removes the text slide and map animation. Typing and the analysis delay use cancellable SwiftUI tasks keyed to the stage, tour run and scene activity. Skip/account changes remove the simulation without replacing the real journal or triggering analysis.

`GuidedTourSimulation` in DailyCore owns the transition rules and immutable synthetic graph. It has no account, network, database or AI dependencies. The real social profile form appears only after the example is finished, with its existing research-consent default retained.

## Validation

Local configuration/signing tests and Swift grammar parsing can run on Windows; these do not compile or render SwiftUI. Native build, simulator and physical-device verification remain pending a new Codemagic build.

`GuidedTourSimulationTests` checks action gates, graph validity and answer persistence/reset. `GuidedTourUITests` exercises the actual highlighted logo, analysis sheet, map node, note window, answer-dependent agenda, export, consent and skipping during analysis. It saves screenshots to the native xcresult. UI tests can use the DEBUG-only `-daily-tour-hold-analysis` flag to inspect the transient window for four seconds; the release delay stays one second.

The existing `scripts/verify-ios.sh` runs the native DailyX-CI suite and captures preview screenshots when `DAILYX_CAPTURE_PREVIEW=1`. No App Store submission is part of this change.
