# iCan Eye Firmware

Target: Seeed Studio XIAO ESP32S3 Sense.

The production firmware is the PlatformIO app in `src/main.cpp`. The older
Arduino sketches in `arduino_examples/` are reference prototypes only.

## Current Stack

- Board: `seeed_xiao_esp32s3`
- Platform: `espressif32@6.13.0`
- Framework: Arduino ESP32
- Camera: XIAO Sense camera through `esp_camera`
- BLE peripheral name: `iCan Eye`
- BLE protocol source of truth: `../../protocol/ble_protocol.yaml`

The XIAO ESP32S3 Sense camera examples from Seeed apply to both the older
OV2640 and newer OV3660 camera modules. The firmware therefore avoids
sensor-model-specific assumptions where possible.

## BLE Protocol

Service:

- `20000001-2000-2000-2000-200000000000`

Characteristics:

- `20000002-2000-2000-2000-200000000000`: instant text notify
- `20000003-2000-2000-2000-200000000000`: image stream notify
- `20000004-2000-2000-2000-200000000000`: command write/write-without-response and control notify

Commands from app to Eye:

- `CAPTURE`
- `LIVE_START:{intervalMs}` where firmware clamps to 500-10000 ms
- `LIVE_STOP`
- `PROFILE:{index}`
- `STATUS`

Events from Eye to app:

- `BUTTON:DOUBLE`
- `CAPTURE:START`
- `SIZE:{bytes}`
- `CRC:{hex}`
- `END:{chunks}`
- `STATUS:{profileIndex}:{profileName}:{IDLE|LIVE}:{intervalMs}:{firmwareVersion}`
- `ERR:{code}`

Image chunks are `[uint16_le sequence][jpeg payload]`, capped by negotiated
BLE MTU and `IMAGE_MAX_PAYLOAD`.

## Camera Profiles

| Index | Name | Resolution | JPEG Quality |
| --- | --- | --- | --- |
| 0 | FAST | VGA 640x480 | 12 |
| 1 | BALANCED | SVGA 800x600 | 10 |
| 2 | QUALITY | XGA 1024x768 | 8 |
| 3 | MAX | UXGA 1600x1200 | 8 |

Lower JPEG quality numbers mean higher image quality and larger files.

## Build

Run from `firmware/ican_eye`:

```powershell
py -m platformio run -e xiao_esp32s3
```

Optional isolated builds:

```powershell
py -m platformio run -e test_camera
py -m platformio run -e test_ble_stream
py -m platformio run -e test_blink
```

## Flash

Connect the Eye over USB. Find the COM port:

```powershell
py -m platformio device list
```

Upload, replacing `COM4` with the actual port:

```powershell
py -m platformio run -e xiao_esp32s3 -t upload --upload-port COM4
```

Monitor:

```powershell
py -m platformio device monitor -p COM4 -b 115200
```

Close the monitor before uploading again.

## Demo Acceptance Gate

- Full firmware builds with no camera deprecation warnings.
- App protocol tests pass.
- Eye advertises as `iCan Eye`.
- App connects by Eye service UUID.
- `STATUS` returns a control notification.
- Single press captures and streams a JPEG.
- Double press emits `BUTTON:DOUBLE`.
- `LIVE_START` and `LIVE_STOP` operate without disconnecting.
