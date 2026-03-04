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
// Image Stream Packet Header (Eye → App)
// ===========================================================================
constexpr uint8_t IMAGE_HEADER_BYTES = 5;
constexpr uint8_t IMAGE_MAX_PAYLOAD = 235;
constexpr uint8_t IMAGE_MAX_PACKET_SIZE = 240;

#pragma pack(push, 1)
struct ImagePacketHeader {
  uint16_t sequence_number; // little-endian
  uint16_t total_chunks;    // little-endian
  uint8_t checksum;         // XOR of payload bytes
};
#pragma pack(pop)

static_assert(sizeof(ImagePacketHeader) == IMAGE_HEADER_BYTES,
              "ImagePacketHeader must match IMAGE_HEADER_BYTES");

#endif // BLE_PROTOCOL_H
