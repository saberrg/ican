# Regression Matrix

## Release Blockers
| Area | Owner | Acceptance Gate |
| --- | --- | --- |
| Describe crash recovery | Crash/Describe | Unfinished `DescribeAttemptTrace` appears on next Home launch; failed stages produce diagnostics, not silent crashes. |
| Cloud-first Describe | Crash/Describe | Auto uses Gemini first and local fallback only when native channel plus Apple Vision health pass. |
| Eye readiness | BLE/Firmware | Eye is ready only after image, control, and instant-text notifications subscribe. |
| Demo startup | UI/Speech | Splash always routes Home; caretaker and role selection are not visible startup/settings actions. |
| Speech defaults | UI/Speech | Native iOS/system en-US defaults, rate 0.5, pitch 1.0, volume 1.0. |
| Agent verification | Verification/CI | Format, analyze, tests, offline vision preflight, firmware optional gate documented and runnable. |

## Automated Gates
Run from repo root:

```powershell
dart format lib test
flutter test --no-pub
.\scripts\agent_verify.ps1 -SkipPubGet
.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision
.\scripts\agent_verify.ps1 -SkipPubGet -Firmware
```

Before TestFlight upload, generate and complete the stricter Eye report:

```powershell
.\scripts\eye_release_readiness.ps1 -Firmware -OfflineVision
```

See `docs/eye_testflight_readiness.md` for the real iPhone + Eye matrix.

## iOS And Crash Gates
- Archive/export on the remote Mac before upload.
- Pull TestFlight crash reports through Xcode Organizer or App Store Connect after every crash report.
- Symbolicate locally with matching dSYM before handing off analysis.
- Record crash date, app build, iOS version, device, top crashed thread, and matching `DescribeAttemptTrace` stage.
- Do not commit raw crash logs, Apple account output, user identifiers, or secrets.

## Real Eye Smoke
- Pair iCan Eye from Home.
- Confirm Home speaks `iCan Eye connected.` once.
- Run three Describe captures on iPhone.
- Confirm failed capture reports Eye diagnostic code instead of crashing.
- Confirm disconnect speaks `iCan Eye disconnected.` once.

## Current Demo Risks
- Real Eye BLE capture still needs physical iPhone verification.
- Offline/Core ML model resources may be absent; Auto must remain cloud-first.
- Firmware build depends on local PlatformIO availability.
