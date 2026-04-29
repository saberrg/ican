# iCan Eye TestFlight Readiness

Use this gate before publishing a build to TestFlight. It is intentionally
stricter than the general regression matrix because TestFlight upload does not
prove the physical Eye path.

## Command

From repo root:

```powershell
.\scripts\eye_release_readiness.ps1 -Firmware -OfflineVision
```

For a connected iPhone integration-test run from a Mac:

```powershell
.\scripts\eye_release_readiness.ps1 -Firmware -OfflineVision -Integration -DeviceId <ios-device-id>
```

The script writes a timestamped report under `build\eye_release_readiness\`.
Fill in the hardware matrix in that report and keep it local or attach the
sanitized result to the PR. Do not commit raw crash logs, image bytes, Apple
account output, user identifiers, API keys, or device-owner data.

## Required Order

1. Automated Flutter and protocol gates.
2. Firmware build and host chunk-math tests.
3. Real iPhone integration smoke.
4. Real iCan Eye hardware matrix.
5. TestFlight upload.
6. Xcode Organizer and App Store Connect feedback review.

## Automated Gates

```powershell
dart format lib test integration_test
flutter test --no-pub
.\scripts\agent_verify.ps1 -SkipPubGet
.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision
.\scripts\agent_verify.ps1 -SkipPubGet -Firmware
flutter test integration_test/eye_demo_startup_test.dart --no-pub -d <ios-device-id>
```

The integration test currently verifies the demo startup invariant: Splash
lands on Home and unfinished role/caretaker paths stay hidden.

## Real Eye Hardware Matrix

Record:

- iPhone model and iOS version.
- Eye board serial or label.
- Eye firmware commit/SHA.
- App version/build and TestFlight build number.
- Network state.
- Operator name or initials.

Run:

| Gate | Pass Criteria |
| --- | --- |
| Fresh install launch | Splash lands Home. No caretaker or role-selection route is visible. |
| Pair Eye | App speaks `iCan Eye connected.` once, only after image/control/instant-text notifications and STATUS pass. |
| Idle heartbeat | STATUS heartbeat remains healthy for 2 minutes. |
| FAST captures | 10 captures complete with no Eye E02/E03/E04. |
| BALANCED captures | 5 captures complete with no disconnect. |
| Profiles | PROFILE 0, 1, 2, and 3 receive firmware confirmation and app remains usable. |
| Cloud Describe | Output is useful, hazard-first, one breath, and no banned meta text. |
| Auto mode | Uses cloud first while online. |
| Offline Describe | Runs only if native health checks pass; otherwise diagnostic-only. |
| Live short | 60 seconds, no overlapping analysis/speech, no truncated TTS. |
| Live stress | 5 minutes, no disconnect, stuck speech, or unrecoverable busy state. |
| Stop Live | Sends ABORT/LIVE_STOP and returns to idle. |
| Eye power loss | Disconnect is spoken once; app reconnects cleanly after Eye returns. |
| Button double press | Starts voice listening once. |
| Cloud/network failure | Diagnostic appears and app does not crash. |
| Relaunch after killed Describe | Home surfaces unfinished `DescribeAttemptTrace`. |

## Failure Injection Matrix

Use firmware debug builds or test hooks where possible:

| Injection | Expected Result |
| --- | --- |
| No CAPTURE:START/SIZE | Eye E01 diagnostic. |
| Missing END | Eye E02 diagnostic. |
| STREAM_ABORTED | Eye E02 with sent/expected bytes and chunk count. |
| Truncated JPEG | Eye E03 diagnostic. |
| CRC mismatch | Eye E04 diagnostic. |
| CAMERA_CAPTURE_FAILED | Eye E05 diagnostic. |
| Duplicate chunk | Assembler dedupes; no duplicate bytes in final image. |
| Skipped sequence | `missedChunks` increments and incomplete streams fail. |

## TestFlight Feedback Gate

After an internal TestFlight build:

- Check Xcode Organizer for crashes and energy reports.
- Check App Store Connect TestFlight feedback, screenshots, and crash comments.
- Download and symbolicate crashes with the matching dSYM if needed.
- Record crash date, build, iOS version, device, top crashed thread, and
  matching Describe/Eye diagnostic stage.
- If there is any untriaged crash on the demo path, do not expand testing.
