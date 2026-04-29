/**
 * ============================================================================
 * iCan BLE Protocol — C++ Header (mirrors protocol/ble_protocol.yaml)
 * ============================================================================
 * DO NOT edit UUIDs or opcodes here without updating ble_protocol.yaml first.
 * ============================================================================
 */

#ifndef BLE_PROTOCOL_H
#define BLE_PROTOCOL_H

#include <stdint.h>

// ===========================================================================
// BLE Service UUIDs
// ===========================================================================
#define ICAN_CANE_SERVICE_UUID "10000001-1000-1000-1000-100000000000"
#define ICAN_EYE_SERVICE_UUID "20000001-2000-2000-2000-200000000000"

// ===========================================================================
// BLE Characteristic UUIDs — Cane
// ===========================================================================
#define CHAR_NAV_COMMAND_RX_UUID "10000002-1000-1000-1000-100000000000"
#define CHAR_OBSTACLE_ALERT_TX_UUID "10000003-1000-1000-1000-100000000000"
#define CHAR_IMU_TELEMETRY_TX_UUID "10000004-1000-1000-1000-100000000000"
#define CHAR_CANE_STATUS_TX_UUID "10000005-1000-1000-1000-100000000000"
#define CHAR_GPS_DATA_TX_UUID    "10000006-1000-1000-1000-100000000000"

// ===========================================================================
// BLE Characteristic UUIDs — Eye
// ===========================================================================
#define CHAR_EYE_INSTANT_TEXT_TX_UUID "20000002-2000-2000-2000-200000000000"
#define CHAR_EYE_IMAGE_STREAM_TX_UUID "20000003-2000-2000-2000-200000000000"
#define CHAR_EYE_CAPTURE_RX_UUID "20000004-2000-2000-2000-200000000000"

// ===========================================================================
// Navigation Command Opcodes (App → Cane)
// ===========================================================================
enum NavCommand : uint8_t {
  NAV_STOP = 0x00,
  NAV_TURN_LEFT = 0x01,
  NAV_TURN_RIGHT = 0x02,
  NAV_GO_STRAIGHT = 0x03,
  NAV_U_TURN = 0x04,
  NAV_ARRIVED = 0x05,
  NAV_RECALCULATE = 0x06,
};

// ===========================================================================
// Obstacle Side Codes (Cane → App)
// ===========================================================================
enum ObstacleSide : uint8_t {
  OBSTACLE_NONE = 0x00,
  OBSTACLE_LEFT = 0x01,
  OBSTACLE_RIGHT = 0x02,
  OBSTACLE_HEAD = 0x03,  // LiDAR head-height
  OBSTACLE_FRONT = 0x04, // Both ultrasonics
};

// ===========================================================================
// Haptic Patterns (DRV2605L waveform IDs — internal to Cane firmware)
// ===========================================================================
enum HapticPattern : uint8_t {
  PATTERN_OBSTACLE_LEFT = 1,
  PATTERN_OBSTACLE_RIGHT = 2,
  PATTERN_OBSTACLE_HEAD = 3,
  PATTERN_NAV_LEFT = 4,
  PATTERN_NAV_RIGHT = 5,
  PATTERN_NAV_STRAIGHT = 6,
  PATTERN_ARRIVED = 7,
  PATTERN_FALL_ALERT = 8,
};

// ===========================================================================
// Telemetry Packet (Cane → App, 6 bytes)
// ===========================================================================
#pragma pack(push, 1)
struct TelemetryPacket {
  uint8_t flags; // bit 0 = fall_detected, bit 1 = pulse_valid
  uint8_t pulse_bpm;
  uint8_t battery_percent;
  int16_t yaw_angle; // degrees * 10, little-endian
  uint8_t reserved;

  bool isFallDetected() const { return flags & 0x01; }
  bool isPulseValid() const { return flags & 0x02; }
};
#pragma pack(pop)

static_assert(sizeof(TelemetryPacket) == 6, "TelemetryPacket must be 6 bytes");

// ===========================================================================
// GPS Data Packet (Cane → App, 19 bytes, 1 Hz)
// ===========================================================================
#pragma pack(push, 1)
struct GpsPacket {
  float   latitude;    // decimal degrees (positive=N, negative=S)
  float   longitude;   // decimal degrees (positive=E, negative=W)
  float   altitude_m;  // meters above mean sea level
  float   speed_knots; // speed over ground in knots
  uint8_t satellites;  // number of satellites in use
  uint8_t fix_quality; // 0=invalid, 1=GPS fix, 2=DGPS fix
  uint8_t fix_valid;   // 0=no fix, 1=valid fix acquired
};
#pragma pack(pop)

static_assert(sizeof(GpsPacket) == 19, "GpsPacket must be 19 bytes");

// ===========================================================================
// Eye Command Types (App → Eye via eyeCaptureRx)
// ===========================================================================
// String commands sent over BLE:
//   "CAPTURE"               — single-shot capture
//   "LIVE_START:{ms}"       — start firmware-driven periodic capture at {ms} interval
//   "LIVE_STOP"             — stop firmware-driven periodic capture
//   "PROFILE:{idx}"         — switch camera quality profile
//   "STATUS"                — request current status
//
// Events (Eye → App, notified on same characteristic):
//   "BUTTON:DOUBLE"         — physical button double-press detected
//   "CAPTURE:START"         - capture accepted and camera capture starting
//   "STATUS:{idx}:{name}:{IDLE|LIVE}:{ms}:{firmware}:{freePsram}:{mtu}:{payloadCap}:{lastError}" - status response
//   "SIZE:{bytes}", "CRC:{hex}", "END:{chunks}" - image transfer control
//   "ERR:{code}"            — command error

// ===========================================================================
// Image Stream Packet Header (Eye → App)
// ===========================================================================
constexpr uint8_t IMAGE_HEADER_BYTES = 2;
constexpr uint16_t IMAGE_MAX_PAYLOAD = 509;
constexpr uint16_t IMAGE_MAX_PACKET_SIZE = 512;
// Production firmware clamps each notify payload to this value regardless of
// MTU. Keeps iOS BLE ACL queues from saturating and causing late-stream
// ERR:CHUNK_NOTIFY_FAILED at 97%+ completion. The Flutter assembler reads the
// actual chunk size per packet, so this is safe below IMAGE_MAX_PAYLOAD.
constexpr uint16_t EYE_IMAGE_FIRMWARE_PAYLOAD_CAP = 240;

// ===========================================================================
// Eye Command String Literals (App → Eye via eye_capture_rx, WRITE)
// ===========================================================================
constexpr const char* EYE_CMD_CAPTURE_STR = "CAPTURE";
constexpr const char* EYE_CMD_ABORT_STR   = "ABORT";
constexpr const char* EYE_CMD_LIVE_START_PREFIX = "LIVE_START:";
constexpr const char* EYE_CMD_LIVE_STOP_STR = "LIVE_STOP";
constexpr const char* EYE_CMD_PROFILE_PREFIX = "PROFILE:";
constexpr const char* EYE_CMD_STATUS_STR = "STATUS";

#pragma pack(push, 1)
struct ImagePacketHeader {
  uint16_t sequence_number; // little-endian
};
#pragma pack(pop)

static_assert(sizeof(ImagePacketHeader) == IMAGE_HEADER_BYTES,
              "ImagePacketHeader must match IMAGE_HEADER_BYTES");

#endif // BLE_PROTOCOL_H
