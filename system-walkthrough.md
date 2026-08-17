# iCan Eye Firmware Refactoring Walkthrough

## 🎯 Goal
Refactor the iCan Eye firmware to transition from a monolithic Arduino script ([ble_camera_v2.ino](firmware/ican_eye/src/ble_camera_v2.ino)) to a structured, modular PlatformIO project matching the architecture of the `ican_cane` firmware.

## 🛠️ Changes Implemented

### 1. Project Restructuring & Modularity
- Converted the single [ble_camera_v2.ino](firmware/ican_eye/src/ble_camera_v2.ino) file into a standard `lib/` and `src/` hierarchy.
- **`lib/camera`**: Handles OV2640 hardware initialization, PSRAM checks, image capture, and profile switching.
- **`lib/ble_eye`**: Manages the NimBLE server stack, command parsing, and sequential image chunk packing.
- **[src/main.cpp](firmware/ican_eye/src/main.cpp)**: Acts as the central orchestrator, cleanly polling the camera or Bluetooth without heavy business logic.
- Moved old Python testing scripts (e.g. [receive_photo.py](firmware/ican_eye/src/receive_photo.py)) to a dedicated `test_scripts/` directory to clear out the firmware source tree.
- Extracted and safely removed the old [.ino](firmware/ican_eye/src/ble_camera.ino) backups to avoid confusion.

### 2. Adopting the Shared Protocol
- Linked the Eye firmware to the single source of truth: [shared/include/ble_protocol.h](firmware/shared/include/ble_protocol.h).
- The Eye firmware now correctly uses the shared service UUIDs and command flags (e.g., `ICAN_EYE_SERVICE_UUID`, [ImagePacketHeader](firmware/shared/include/ble_protocol.h#99-104)).
- This ensures the iOS/Android apps can reliably parse incoming Bluetooth data without mismatch bugs.
- Fixed how the PlatformIO `Library Dependency Finder` detects dependencies outside the scope of the project directory.

### 3. Dedicated Test Environments
Set up isolated testing environments in [platformio.ini](firmware/ican_eye/platformio.ini) to allow components to be verified independently:
- **`env:xiao_esp32s3`**: The main application compiling all core features.
- **`env:test_camera`**: Compiles *only* the camera module to verify OV2640 frames independent of BLE constraints.
- **`env:test_ble_stream`**: Compiles *only* the BLE module, streaming dummy byte data instead of real images, ideal for debugging Bluetooth bandwidth limits.

## ✅ Verification
- Since the iCan Eye hardware is currently disconnected, the verification relies on static structural analysis and compilation matching.
- **Build Checks**:
  - `platformio run -e xiao_esp32s3` 👉 **PASSED**
  - `platformio run -e test_camera` 👉 **PASSED**
  - `platformio run -e test_ble_stream` 👉 **PASSED**
- All linker warnings and missing [camera_pins.h](firmware/ican_eye/include/camera_pins.h) dependency issues between the local library contexts are successfully resolved.

## 🚀 Next Steps
Once the ESP32-S3 hardware is connected via USB, you can flash the environments using:
```bash
# Flash the main Eye application
pio run -t upload -e xiao_esp32s3

# Flash individual module tests if you need to debug specific components:
pio run -t upload -e test_camera
pio run -t upload -e test_ble_stream
```
You should also run the Python testing script located at `test_scripts/receive_photo.py` with the hardware to verify chunked data streaming physically works end-to-end.
