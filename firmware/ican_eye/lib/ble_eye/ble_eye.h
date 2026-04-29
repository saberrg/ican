/**
 * ble_eye.h — BLE Peripheral Communication Layer for iCan Eye
 *
 * Sets up the BLE server on the XIAO ESP32-S3 with the iCan Eye service
 * and characteristics defined in ble_protocol.h.
 *
 * Provides a high-level API: init, send photo, handle commands.
 */

#ifndef BLE_EYE_H
#define BLE_EYE_H

#include "ble_protocol.h"
#include <stddef.h>
#include <stdint.h>

// =========================================================================
// Command callback — called when a BLE client sends a command
// =========================================================================

/** Command types the Eye can receive. */
enum EyeCommand : uint8_t {
  EYE_CMD_NONE = 0,
  EYE_CMD_CAPTURE = 1,
  EYE_CMD_PROFILE = 2,
  EYE_CMD_STATUS = 3,
  EYE_CMD_LIVE_START = 4,
  EYE_CMD_LIVE_STOP = 5,
  EYE_CMD_ABORT = 6,
  EYE_CMD_ACK_FRAME = 7,
  EYE_CMD_NACK_FRAME = 8,
  EYE_CMD_WIFI = 9,
};

/** Parsed command from BLE client. */
struct EyeCommandData {
  EyeCommand type;
  int profileIndex;   // valid when type == EYE_CMD_PROFILE
  int liveIntervalMs; // valid when type == EYE_CMD_LIVE_START
  uint16_t frameId;   // valid for ACK_FRAME/NACK_FRAME
  char nackRanges[80]; // also reused as payload for EYE_CMD_WIFI: "ssid;pw"
};

// =========================================================================
// Public API
// =========================================================================

/**
 * Initialize BLE peripheral with the iCan Eye service.
 * Creates characteristics for image streaming and capture control.
 * Starts advertising as "iCan Eye".
 */
void initBleEye();

/**
 * Check if a BLE client (phone/PC) is currently connected.
 */
bool isBleEyeConnected();

/**
 * Get the last command received from the BLE client.
 * Returns EYE_CMD_NONE if no command pending.
 * Calling this clears the pending command.
 */
EyeCommandData getLastEyeCommand();

/**
 * Send a status/control message to the connected client via the
 * control (capture) characteristic as a notify.
 * Examples: "SIZE:12345", "END:42", "STATUS:1:BALANCED:IDLE:1500"
 * STATUS may append diagnostics such as PSRAM, MTU, stream stats, and camera
 * quality estimates; app parsing keeps those trailing fields optional.
 */
void sendControlMessage(const char *msg);

uint16_t getBleEyeNegotiatedMtu();

uint16_t getBleEyePayloadCap();

uint32_t getBleEyeLastStreamBytes();

uint32_t getBleEyeLastStreamMs();

uint16_t getBleEyeLastStreamChunks();

const char *getBleEyeLastStreamResult();

/**
 * Send a single image data chunk to the connected client.
 * Packs a 2-byte sequence number header and payload per ble_protocol.h.
 *
 * @param seqNum   Chunk sequence number (0-based).
 * @param data     Pointer to JPEG data for this chunk.
 * @param dataLen  Number of payload bytes (capped to MTU-based effective max).
 * @return         Actual bytes of payload sent (used to advance the offset).
 */
size_t sendImageChunk(uint16_t frameId, uint16_t seqNum, const uint8_t *data,
                      size_t dataLen);

void acknowledgeImageFrame(uint16_t frameId);

bool retransmitImageFrameRanges(uint16_t frameId, const char *ranges);

/**
 * High-level: stream an entire JPEG buffer over BLE.
 * Sends SIZE control message, image chunks, and END message.
 *
 * @param jpegBuf      Pointer to JPEG data.
 * @param jpegLen      Length of JPEG data in bytes.
 * @param profileName  Name of the camera profile (for logging only).
 */
void streamImageViaBle(const uint8_t *jpegBuf, size_t jpegLen,
                       const char *profileName);

#endif // BLE_EYE_H
