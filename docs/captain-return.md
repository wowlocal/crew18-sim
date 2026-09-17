# Captain return

The existing single-slot ExpeditionRecovery remains responsible for atomic saves,
validation, notification serialization/cancellation and paused restoration. No physics
or balance changes are required.

## Routing

AppRoute is Codable. NavigationCoordinator is observable, main-actor isolated and
buffers the most recent route before GameView connects. Duplicate taps within one
second are ignored; ExpeditionRecovery separately prevents duplicate restoration.
URLs keep the existing `podlodkadive://expedition/<UUID>` contract. Additional hosts:
`briefing/<UUID>`, `campaign/<mission raw value>`, `journal[/<UUID>]`,
`blackbox/<UUID>`, `events`, `continue`. Credentials, ports, queries, fragments and
extra path components are rejected. Missing/invalid saves create a restoreError
history entry. An active game is preserved while replacement is confirmed; a stale
link from Home stays on Home. Campaign routes select unlocked missions from Home;
while playing they open the campaign chooser without replacing the active game.
Notification actions and App Intents enter the same coordinator. The legacy
ReturnInbox remains an adapter for callers using the previous URL interface.

## Scheduling and restoration

Planner thresholds are named constants: within 350 world units of delivery -> one
hour; returning cargo, energy <=25 or hull <=1 -> one day; otherwise -> seven days.
The hour/day tiers include a seven-day fallback. Stable request identifiers replace
previous schedules; all three identifiers (including the legacy pair) are cancelled
on restore, completion or deletion. Calendar components preserve local wall time.
Later replaces the schedule with +1/+7 calendar days and does not restore the game.
DateProvider and the existing closure clock are injectable. Notification permission
failure never prevents saving or manual restoration.

New saves carry schemaVersion 2 and savedAt. Existing version-1 saves without these
optional fields migrate in memory and are rewritten on the next save. Unknown
schema versions and corrupt saves use the existing explicit recovery fallback.
An unknown legacy timestamp displays zero elapsed days rather than inventing a date.

The return screen keeps the engine paused, reuses ExpeditionMap and reads the
saved run through BlackBoxReader. It presents the objective, saved resources, recent
events, latest successful captain note and elapsed days. Continue consumes the
briefing once; Restart requires confirmation. Recovery domain events share their
UUID with BlackBox entries and retain the existing captain-log sink. The histories
are separate storage backends, not a cross-store transaction: a process kill between
writes can still leave a missing log entry. Multi-slot saves, remote push, background
execution and Live Activities are outside this implementation.

## Validation

Unit additions cover planner tiers, rescheduling/snooze/cancellation, URL rejection,
Codable routes, cold-start buffering, tap deduplication, double resume, legacy schema
migration and briefing fixture isolation. UI additions audit the briefing and event
screen and exercise journal/event routes. Existing tests cover exact engine restore,
notification denial, stale links, confirmation and terminal save cleanup.

Device smoke test: save and exit, inspect scheduled local notifications, tap Continue
with the app terminated, verify the briefing and saved position, then resume. Repeat
with Later and permission denied. Invoke both localized App Shortcuts via Siri.
System notification delivery and Siri recognition require this manual device check;
unit/UI tests exercise their underlying route and scheduling contracts.

### Observed checks (2026-09-17)

- iOS Simulator build and App Intents metadata extraction succeeded (Xcode SDK 27,
  iOS 26.5 simulator).
- 106 unit tests passed, including six new recovery/router tests.
- The new briefing accessibility test passed after explicit button contrast and
  human-readable event projection were added. Journal/events routing and the
  save → events → briefing → relaunch scenario passed.
- The existing all-screen audit reports contrast on `nextMission` on the completed
  screen. An explicit black text override did not change the failure; its exported
  screenshot shows black text on the existing gold background. The unrelated
  button style is preserved; this audit failure is not suppressed.
- Initial parallel simulator runs encountered launch failures; verification used
  sequential execution. See the task report for final result-bundle paths.
- Dactyl regeneration is reproducible; Swift syntax, project plist, catalog JSON
  and whitespace checks passed.
