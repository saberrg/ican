# iCan Presentation Demo

Use this as the official class-demo runbook. Keep the demo focused: assistive cane hardware, iCan Eye capture, scene description, live cues, and spoken output.

## One-sentence pitch

*iCan helps a blind or low-vision user understand the space in front of them by combining a smart cane, a BLE camera module, cloud/local vision, and spoken feedback from an iOS app.*

## Core demo path

1. **Open the app**
   - Show the iCan home/command center.
   - Point out BLE/iCan Eye status and current vision mode.

2. **Connect hardware**
   - Pair/connect the cane or iCan Eye over BLE.
   - Confirm the app can send Eye commands.

3. **Describe now**
   - Trigger a capture from the iCan Eye.
   - The Eye sends JPEG data over BLE.
   - The app routes the image through the selected available backend.
   - The app speaks the scene description aloud.

4. **Switch backend or prompt behavior**
   - Demonstrate a mode such as cloud, auto, or local/offline if available on the device.
   - Emphasize that the app checks backend health and falls back truthfully.

5. **Start live vision**
   - Start periodic iCan Eye capture.
   - The firmware uses `LIVE_START:{intervalMs}` and streams frames without requiring a manual capture each time.
   - The app announces short live cues instead of long paragraphs.

6. **Stop live vision**
   - Stop the stream cleanly with the app control or voice flow.
   - Confirm the system returns to normal on-demand description.

## What to say out loud

- “This is not just a static app mockup. The BLE camera protocol, live capture command, local/offline vision path, cloud routing, and spoken output are implemented in the repo.”
- “For the most reliable presentation result, Gemini gives the high-quality online description.”
- “The local/offline path is implemented with runtime health checks. On the demo device, we verify which model path is available and the app falls back instead of overclaiming.”
- “Live vision is designed for short repeated cues while walking, not a long essay every frame.”

## Demo roles

- **Presenter:** narrates the problem, system, and result.
- **Operator:** controls the phone, BLE connection, capture, and live mode.
- **Hardware handler:** points the iCan Eye/cane at prepared scenes and keeps lighting stable.

## Prepared scene checklist

Use simple scenes that are easy for both cloud and local backends:

- Bright room lighting.
- One or two obvious objects.
- At least one readable sign or label if testing OCR.
- A person or chair positioned clearly left/center/right if testing spatial cues.
- Avoid motion blur during capture.

## Fallback script

If hardware or a model backend is unavailable during the presentation, do not improvise claims. Use this wording:

- “The app is detecting that this backend is unavailable on this device/session, so it is falling back to the safer path.”
- “The implemented path is in the repo; for live demo reliability we are showing the verified backend now.”
- “That fallback behavior is part of the design because an assistive system should fail honestly.”

## Pre-demo verification

Before presenting, verify:

- Phone has the expected build installed.
- BLE hardware powers on and appears to the app.
- iCan Eye can capture at least one JPEG.
- Cloud mode has internet and an API key.
- Local/offline mode reports backend health in the diagnostic screen.
- Live mode starts and stops cleanly.
- Speaker volume and Bluetooth audio route are correct.

Reference docs:

- [`TECHNICAL_OVERVIEW.md`](TECHNICAL_OVERVIEW.md)
- [`OFFLINE_VISION_VERIFICATION.md`](OFFLINE_VISION_VERIFICATION.md)
- [`ican_eye_vision_architecture.md`](ican_eye_vision_architecture.md)
