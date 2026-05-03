# iCan Technical Overview

This is the concise source for how the presentation system fits together.

## System components

- **Smart cane / iCan Eye hardware:** ESP32-S3 camera module and cane electronics.
- **BLE protocol:** app-to-device commands for capture, live capture, status, and image transfer.
- **Flutter iOS app:** accessible UI, BLE services, voice control, scene-description routing, settings, and text-to-speech.
- **Vision backends:** cloud Gemini path plus local/offline paths with health checks and fallback.
- **Speech output:** iOS text-to-speech announces scene descriptions and live cues.

## End-to-end flow

```text
User requests description
        |
        v
Flutter app sends BLE capture command
        |
        v
iCan Eye captures JPEG frame
        |
        v
BLE transfers image bytes to app
        |
        v
SceneDescriptionService selects backend
        |
        +--> Gemini cloud, if online/selected
        +--> Foundation Models path, if available
        +--> SmolVLM/local VLM path, if available
        +--> Vision-only fallback
        |
        v
App speaks result through TTS
```

## Live vision flow

Live vision is an implemented path, not just a future idea.

- App entry point: `HomeViewModel.startLiveVision()` in `lib/models/home_view_model.dart`.
- The app checks offline/on-device vision status before choosing full or basic live mode.
- The app starts firmware-driven capture with `BleService.instance.startLiveCapture(intervalMs: 1500)`.
- Protocol command: `LIVE_START:{intervalMs}` in `lib/protocol/ble_protocol.dart` and `protocol/ble_protocol.yaml`.
- Firmware parses and handles live start/stop under `firmware/ican_eye/`.
- Full live mode announces object/spatial cues when object detection is available.
- Basic live mode still reports simpler cues such as people/text/scene classification when full object detection is degraded.

## Local/offline vision

Local/offline support is implemented as a runtime-routed pipeline with health checks. The correct presentation framing is:

- The code supports local/on-device backends.
- Exact backend availability depends on device OS, bundled/downloaded model files, memory, and build configuration.
- If a local model is unavailable, the app should fall back to a safer backend and report that status honestly.

Relevant implementation areas:

- `lib/services/on_device_vision_service.dart` — local analysis and backend health/status.
- `lib/services/scene_description_service.dart` — cloud/local routing and backend selection.
- `lib/screens/vision_diagnostic_screen.dart` — hidden diagnostics for backend verification.
- `docs/OFFLINE_VISION_VERIFICATION.md` — manual checks for each backend.

## Cloud vision

The Gemini path provides the cleanest high-quality description for demo reliability when internet and API configuration are available.

Relevant implementation area:

- `lib/services/scene_description_service.dart`

## BLE and firmware

The app and firmware share a small command vocabulary for still capture and live capture.

Important anchors:

- `lib/protocol/ble_protocol.dart`
- `protocol/ble_protocol.yaml`
- `firmware/ican_eye/lib/ble_eye/`
- `firmware/ican_eye/src/main.cpp`

Presentation framing:

- Still capture proves the app can request a frame and describe it.
- Live capture proves the Eye can stream repeated frames for short spoken cues.
- The system should be demoed with stable lighting and verified hardware to avoid BLE/camera noise distracting from the core idea.

## What not to overclaim

Avoid saying:

- “Every model always runs offline on every phone.”
- “Live mode is production-ready for outdoor navigation.”
- “The system replaces a mobility aid or human guide.”

Safe wording:

- “The repo implements local/offline and live vision paths with runtime availability checks.”
- “The demo shows a working assistive prototype with honest fallback behavior.”
- “The cloud path is the most reliable presentation backend; local paths are verified per device.”
