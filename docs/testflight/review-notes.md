# TestFlight — preparation, 18 September 2026 target

Draft only. Update against the final integrated commit before upload.

## Beta description
Podlodka Dive is a single-player submarine exploration game developed during the Podlodka iOS Crew 18 event. Explore underwater areas, recover cargo, manage energy, and return to base. The game includes VoiceOver controls, expedition journals, saved expeditions, and optional local reminders.

## What to test
Start an expedition, steer the submarine, collect cargo, and return to base. Try the campaign, VoiceOver controls, save-and-resume flow, local reminders, and expedition journals. Please report crashes, confusing controls, accessibility issues, and failures to restore a saved expedition. Final participant features will be listed after integration.

## Beta App Review notes
No login or demo account is required. This is a native single-player game. Microphone and speech recognition access are optional and used for captain voice notes; speech recognition requires on-device support and has no cloud fallback. Notification permission is optional and used for local expedition reminders. Denying these permissions should not block the main game.

Review steps: launch; start the first expedition; move using the on-screen control; pause and save; return to the home screen and resume. Journals can be opened from the home screen. VoiceOver offers directional actions for steering. Verify these instructions on the final binary.

## Request for expedited Beta App Review — draft
Hello App Review team,

We would like to ask whether you can expedite the TestFlight Beta App Review for Podlodka Dive (Apple ID: 6813200035; version/build: TO BE ASSIGNED). We are organizing Podlodka iOS Crew 18 and would like to distribute the completed community-built game to participants on 18 September 2026.

The build brings together contributions from the event, and participants would like to try the resulting game on their iPhones. The app does not require an account.

Event link: TO BE PROVIDED
Requested availability time and time zone: TO BE PROVIDED
Contact: TO BE PROVIDED

We understand expedited review is discretionary. If the expedited review form does not apply to TestFlight Beta App Review, please advise on the appropriate process. Thank you.

## Remaining release inputs
- Apple Developer team H8QG3CBM96; bundle ID io.podlodka.dive registered. App Store Connect app 6813200035 created (Podlodka Dive, Russian primary locale).
- Review contact name/email/phone and feedback email.
- Privacy policy URL and confirmed privacy declarations for final code.
- Final merged commit, unique build number, distribution signing.
- Final archive validation, device smoke, regression/accessibility checks, external tester group/public link.
- Confirm Xcode 27 SDK eligibility for App Store Connect; do not assume simulator success implies upload acceptance.

## Privacy manifest
UserDefaults stores app-owned settings/progress (CA92.1); systemUptime measures in-app intervals (35F9.1). No app network client/tracking SDK was found in reviewed main 883c2eb. Re-audit after integrating pending features.

Sources:
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/
- https://developer.apple.com/app-store/review/
- https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
