# iCan Agent Operating Rules

## Demo Priority
- The release blocker is Describe stability on iPhone with iCan Eye.
- Splash reads the persisted role from `DevicePrefsService`:
  - No role saved (first launch) → `/dev/role-selection`.
  - `user` → `/` (Home).
  - `caretaker` → `/dev/caretaker-dashboard`.
- Role Selection writes the choice, then routes User → Home (or Device Pairing on first pair) and Caretaker → Caretaker Dashboard.
- Auto vision mode is cloud-first. Local/native fallback is allowed only after native Vision health checks prove it is usable.

## Eye Button Contract
The physical button on the iCan Eye sends `BUTTON:SINGLE / BUTTON:DOUBLE / BUTTON:LONG` on the capture RX characteristic. The owning mapping is in `HomeViewModel._buttonSub`:
- **SINGLE** → run the active describe pipeline (Cloud or Local). No-op while Live is running.
- **DOUBLE** → toggle Cloud ↔ Local describe mode. Stops Live first if it's running. TTS announces the new mode.
- **LONG** → toggle Live detection on/off.

Voice command is **not** hardware-triggered; it's reached from the in-app Listen button only. `VoiceCommandService._onButtonEvent` is intentionally empty — do not re-wire it to DOUBLE.

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
- Do not hard-code Splash to `/` — always respect the saved role per the Demo Priority section.
- Do not re-bind the Eye hardware DOUBLE press to voice. Voice is in-app only.
- Do not revert the button contract to "long cycles modes" — LONG is a Live toggle now.
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
