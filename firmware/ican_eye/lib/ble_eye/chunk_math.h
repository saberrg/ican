#ifndef CHUNK_MATH_H
#define CHUNK_MATH_H

#include <stddef.h>
#include <stdint.h>

#include "ble_protocol.h"

// Pure helpers extracted from ble_eye.cpp so they can be unit-tested under
// PlatformIO env:native (host build). Keeping these header-only avoids any
// link-time coupling to the BLE stack.

namespace ican_eye_chunk_math {

// Given a negotiated ATT MTU, return the number of JPEG payload bytes that
// fit in a single notify. ATT header = 3 bytes, image packet header =
// IMAGE_HEADER_BYTES. Result is clamped to [0, IMAGE_MAX_PAYLOAD] and then
// further clamped to EYE_IMAGE_FIRMWARE_PAYLOAD_CAP so we never blast chunks
// large enough to saturate the iOS ACL queue.
inline size_t effectivePayloadBytes(uint16_t mtu) {
  const size_t overhead = 3 + IMAGE_HEADER_BYTES; // ATT + seq header
  if (mtu <= overhead) return 0;
  size_t mtuPayload = (size_t)mtu - overhead;
  size_t capped = mtuPayload < (size_t)IMAGE_MAX_PAYLOAD
                      ? mtuPayload
                      : (size_t)IMAGE_MAX_PAYLOAD;
  if (capped > (size_t)EYE_IMAGE_FIRMWARE_PAYLOAD_CAP) {
    capped = (size_t)EYE_IMAGE_FIRMWARE_PAYLOAD_CAP;
  }
  return capped;
}

// Pack a v2 frame/chunk header into the first four bytes of a chunk buffer
// (little endian, matching ImagePacketHeader).
inline void packFrameSeqLE(uint8_t *buf, uint16_t frameId, uint16_t seq) {
  buf[0] = (uint8_t)(frameId & 0xFF);
  buf[1] = (uint8_t)((frameId >> 8) & 0xFF);
  buf[2] = (uint8_t)(seq & 0xFF);
  buf[3] = (uint8_t)((seq >> 8) & 0xFF);
}

inline void packSeqLE(uint8_t *buf, uint16_t seq) {
  packFrameSeqLE(buf, 0, seq);
}

// Backoff schedule for sendNotify retries. `attempt` is zero-based. When
// `isNoMem` is true (ESP_ERR_NO_MEM — BLE TX buffer exhausted) we yield
// longer so the controller can drain; otherwise a shorter ramp is enough.
// Keeps the total budget bounded so a stuck connection fails fast.
inline int computeBackoffMs(int attempt, bool isNoMem) {
  if (attempt < 0) attempt = 0;
  if (isNoMem) {
    if (attempt < 5) return 20;
    if (attempt < 15) return 50;
    return 100;
  }
  if (attempt < 5) return 5;
  if (attempt < 15) return 20;
  return 50;
}

// Max attempts before `sendNotify` gives up on a single chunk. Exposed so the
// host tests can exercise the budget without hard-coding the constant.
inline int maxNotifyRetries() { return 40; }

// Drain gap policy: every N successful chunks, the caller should actively
// wait for the TX buffer to drain even if no congestion was observed. This
// keeps sustained transfers from walking the queue up to saturation.
inline int drainGapEveryNChunks() { return 16; }

inline bool appleConnectionParamsAreValid(uint16_t intervalMin,
                                          uint16_t intervalMax,
                                          uint16_t latency,
                                          uint16_t supervisionTimeout) {
  if (intervalMin < 12 || intervalMax < intervalMin) return false;
  if (supervisionTimeout < 200 || supervisionTimeout > 600) return false;
  const uint32_t intervalMaxMsTimes10 = (uint32_t)intervalMax * 125 / 10;
  return intervalMaxMsTimes10 * (latency + 1) * 3 <
         (uint32_t)supervisionTimeout * 10;
}

} // namespace ican_eye_chunk_math

#endif // CHUNK_MATH_H
