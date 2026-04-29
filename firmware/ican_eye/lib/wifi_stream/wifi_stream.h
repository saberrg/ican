#ifndef WIFI_STREAM_H
#define WIFI_STREAM_H

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

void initWifiStream();
bool isWifiConnected();

/**
 * Send a JPEG frame over UDP as one or more datagrams.
 *
 * Each datagram is prefixed with an 8-byte little-endian header:
 *   uint16_t frame_id       // caller-supplied, increments per frame
 *   uint16_t chunk_index    // 0-based index of this datagram in the frame
 *   uint16_t chunk_count    // total datagrams that compose the frame
 *   uint16_t payload_len    // JPEG payload bytes in this datagram (<= 1428)
 *
 * Caller is responsible for checking isWifiConnected() before calling.
 */
void sendFrame(uint8_t* fb, size_t len, uint16_t frameId);

/**
 * Update the SSID/password used by tryConnectWifi().  Credentials are kept
 * in RAM only; the caller (main.cpp) owns NVS persistence.
 */
void setWifiCredentials(const String& newSsid, const String& newPassword);

/** True if non-empty credentials are currently in RAM. */
bool hasWifiCredentials();

/**
 * Non-blocking: starts an asynchronous WiFi.begin() with the current
 * credentials (no-op if none set).  Poll isWifiConnected() to observe
 * the outcome.
 */
void tryConnectWifi();

#endif
