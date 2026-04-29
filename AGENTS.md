# iCan Agent Operating Rules

## Demo Priority
- The release blocker is Describe stability on iPhone with iCan Eye.
- Splash must land on Home. Caretaker and role-selection paths stay hidden unless opened through a tested dev path.
- Auto vision mode is cloud-first. Local/native fallback is allowed only after native Vision health checks prove it is usable.

## Workstream Ownership
- Crash/Describe: `lib/models/home_view_model.dart`, `lib/services/scene_description_service.dart`, `lib/services/scene_prompt_builder.dart`, Describe tests.
- BLE/Firmware: `lib/services/ble_service.dart`, `lib/protocol/*`, `protocol/ble_protocol.yaml`, `firmware/ican_eye`, protocol tests.
- UI/Speech: `lib/screens/accessible_home_screen.dart`, `lib/screens/settings_screen.dart`, `lib/screens/splash_screen.dart`, `lib/services/tts_service.dart`, widget/settings tests.
- Verification/CI: `.github/workflows/*`, `scripts/*`, `docs/*`, regression matrix.

Agents should not edit another active workstream unless the task explicitly requires it.

## Forbidden Shortcuts
- Do not mark Eye connected before required Eye notifications are subscribed.
- Do not speak partial Gemini output as a complete scene description.
- Do not enable local/offline vision fallback in Auto when native Vision health is unavailable.
- Do not route startup to caretaker or role selection for the demo path.
- Do not claim hardware validation without real-device notes.

## Required Gates
Run the narrowest relevant tests while working, then run:

```powershell
dart format lib test
flutter test --no-pub
.\scripts\agent_verify.ps1 -SkipPubGet
.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision
```

Before TestFlight upload also run firmware and iOS gates listed in `docs/regression_matrix.md`.

## Crash Collection
Keep symbolicated crash logs and Apple account output private/local. Store handoff notes without secrets, API keys, Apple IDs, or user data.

## Development MCPs
- Use `espressif-docs` for ESP32-S3, BLE, camera, PSRAM, ESP-IDF, and Arduino-ESP32 documentation research.
- Use `context7` for current Flutter, Dart, package, and SDK API examples before changing package-dependent code.
- Use `firebase` for Firebase, Crashlytics, App Distribution, Remote Config, and tester workflow research.
- Do not add or use experimental hardware MCPs for BLE/serial/iOS automation unless the task explicitly requires hardware validation.
