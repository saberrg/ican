/**
 * ble_eye.cpp — BLE Peripheral Implementation for iCan Eye
 *
 * Uses the standard ESP32 BLEDevice library (built into the Arduino framework)
 * instead of NimBLE. This avoids the PHY initialization race condition that
 * NimBLE 1.4.1 has with ESP32-S3 + Arduino Core 3.x (ESP-IDF 5.1), where the
 * Bluetooth radio hardware never powers on despite the API returning success.
 *
 * Uses the shared BLE protocol UUIDs and packet structures from
 * ble_protocol.h to ensure consistency with the Cane firmware and
 * the Flutter app.
 */

#include "ble_eye.h"
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_gatts_api.h>
#include <esp_gatt_common_api.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <string>
#include <cstdio>
#include "ble_protocol.h"

// =========================================================================
// Internal State
// =========================================================================

static BLEServer *pServer = nullptr;
static BLECharacteristic *pImageStreamChar = nullptr; // image chunks TX
static BLECharacteristic *pInstantTextChar = nullptr; // instant text TX
static BLECharacteristic *pCaptureChar = nullptr;     // capture command RX

static volatile bool clientConnected = false;  // bool read/write is atomic on Xtensa
static volatile bool s_congested = false;      // set by ESP_GATTS_CONGEST_EVT
static uint16_t s_negotiatedMtu = 23;          // BLE default ATT MTU

// Captured from ESP-IDF GATTS events — lets us bypass the Arduino BLE
// library's notify() wrapper (which returns void and silently drops
// notifications) and call esp_ble_gatts_send_indicate() directly.
static volatile uint16_t s_gattsIf = 0;
static volatile uint16_t s_connId = 0;

static portMUX_TYPE s_cmdMux = portMUX_INITIALIZER_UNLOCKED;
static EyeCommand pendingCmdType = EYE_CMD_NONE;
static int pendingCmdProfile = 0;
static int pendingCmdLiveInterval = 0;

// =========================================================================
// BLE Callbacks
// =========================================================================

class EyeServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server, esp_ble_gatts_cb_param_t *param) override {
    clientConnected = true;
    s_congested = false;
    s_negotiatedMtu = 23;  // Reset to safe default; updated by onMtuChanged
    Serial.println("[BLE] Client connected. MTU reset to default.");

    // Request an iOS-friendly interval: 30-50ms with a longer supervision
    // timeout. This is less aggressive than the earlier 15-30ms request and
    // avoids random CoreBluetooth disconnects during image transfer.
    pServer->updateConnParams(param->connect.remote_bda, 24, 40, 0, 400);
  }

  void onDisconnect(BLEServer *server) override {
    clientConnected = false;
    s_congested = false;
    s_connId = 0;
    s_gattsIf = 0;
    Serial.println("[BLE] Client disconnected. Restarting advertising shortly.");
    delay(250);
    BLEDevice::startAdvertising();
  }

  void onMtuChanged(BLEServer *server, esp_ble_gatts_cb_param_t *param) override {
    s_negotiatedMtu = param->mtu.mtu;
    Serial.printf("[BLE] MTU updated to %d bytes\n", s_negotiatedMtu);
  }
};

// Custom GATTS handler — registered via BLEDevice::setCustomGattsHandler().
// Runs alongside the Arduino BLE library's built-in handler.
//
// We use this to:
// 1. Capture gatts_if and conn_id so we can call esp_ble_gatts_send_indicate()
//    directly (BLEServer::getGattsIf/getConnId are private in this version).
// 2. Track congestion state via ESP_GATTS_CONGEST_EVT.
static void eyeGattsEventHandler(esp_gatts_cb_event_t event,
                                 esp_gatt_if_t gatts_if,
                                 esp_ble_gatts_cb_param_t *param) {
  // Always capture the interface handle — it's the same for all events
  // on this GATT server.
  s_gattsIf = gatts_if;

  switch (event) {
    case ESP_GATTS_CONNECT_EVT:
      s_connId = param->connect.conn_id;
      Serial.printf("[BLE] GATTS connect: gatts_if=%u conn_id=%u\n",
                    gatts_if, param->connect.conn_id);
      break;

    case ESP_GATTS_DISCONNECT_EVT:
      Serial.printf("[BLE] GATTS disconnect: gatts_if=%u conn_id=%u reason=0x%02X\n",
                    gatts_if, param->disconnect.conn_id,
                    param->disconnect.reason);
      s_connId = 0;
      s_gattsIf = 0;
      s_congested = false;
      break;

    case ESP_GATTS_CONGEST_EVT:
      s_congested = param->congest.congested;
      Serial.printf("[BLE] TX %s\n",
                    s_congested ? "CONGESTED" : "congestion cleared");
      break;

    default:
      break;
  }
}

class CaptureCommandCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pChar) override {
    String cmd = pChar->getValue().c_str();

    if (cmd == "CAPTURE") {
      portENTER_CRITICAL(&s_cmdMux);
      pendingCmdType = EYE_CMD_CAPTURE;
      pendingCmdProfile = 0;
      portEXIT_CRITICAL(&s_cmdMux);
      Serial.println("[BLE] CAPTURE command received");
    } else if (cmd.startsWith("LIVE_START:")) {
      int intervalMs = cmd.substring(11).toInt();
      if (intervalMs < 500) intervalMs = 500;
      if (intervalMs > 10000) intervalMs = 10000;
      portENTER_CRITICAL(&s_cmdMux);
      pendingCmdType = EYE_CMD_LIVE_START;
      pendingCmdProfile = 0;
      pendingCmdLiveInterval = intervalMs;
      portEXIT_CRITICAL(&s_cmdMux);
      Serial.printf("[BLE] LIVE_START command received: %dms\n", intervalMs);
    } else if (cmd == "LIVE_STOP") {
      portENTER_CRITICAL(&s_cmdMux);
      pendingCmdType = EYE_CMD_LIVE_STOP;
      pendingCmdProfile = 0;
      portEXIT_CRITICAL(&s_cmdMux);
      Serial.println("[BLE] LIVE_STOP command received");
    } else if (cmd.startsWith("PROFILE:")) {
      int idx = cmd.substring(8).toInt();
      portENTER_CRITICAL(&s_cmdMux);
      pendingCmdType = EYE_CMD_PROFILE;
      pendingCmdProfile = idx;
      portEXIT_CRITICAL(&s_cmdMux);
      Serial.printf("[BLE] PROFILE command received: %d\n", idx);
    } else if (cmd == "STATUS") {
      portENTER_CRITICAL(&s_cmdMux);
      pendingCmdType = EYE_CMD_STATUS;
      pendingCmdProfile = 0;
      portEXIT_CRITICAL(&s_cmdMux);
      Serial.println("[BLE] STATUS command received");
    } else {
      Serial.printf("[BLE] Unknown command: %s\n", cmd.c_str());
      sendControlMessage("ERR:UNKNOWN_COMMAND");
    }
  }
};

// =========================================================================
// Public API — Init
// =========================================================================

void initBleEye() {
  BLEDevice::init("iCan Eye");

  // Advertise support for the maximum ATT MTU (517 bytes = 514 payload + 3
  // ATT header). The actual MTU is negotiated per-connection; this sets the
  // upper bound so the phone can request the largest possible value.
  esp_ble_gatt_set_local_mtu(517);

  // Register a custom GATTS handler to capture gatts_if/conn_id and
  // congestion events. Runs alongside the library's built-in handler.
  BLEDevice::setCustomGattsHandler(eyeGattsEventHandler);

  // Allow the BLE stack/radio to stabilize after init
  delay(100);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new EyeServerCallbacks());

  // Create Eye Service
  BLEService *pService = pServer->createService(ICAN_EYE_SERVICE_UUID);

  // Image Stream characteristic — notify image chunks to client
  pImageStreamChar = pService->createCharacteristic(
      CHAR_EYE_IMAGE_STREAM_TX_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  pImageStreamChar->addDescriptor(new BLE2902());

  // Instant Text characteristic — notify quick detection text to client
  pInstantTextChar = pService->createCharacteristic(
      CHAR_EYE_INSTANT_TEXT_TX_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  pInstantTextChar->addDescriptor(new BLE2902());

  // Capture Control characteristic — client writes commands, server notifies status
  pCaptureChar = pService->createCharacteristic(
      CHAR_EYE_CAPTURE_RX_UUID,
      BLECharacteristic::PROPERTY_WRITE |
          BLECharacteristic::PROPERTY_WRITE_NR |
          BLECharacteristic::PROPERTY_NOTIFY);
  pCaptureChar->setCallbacks(new CaptureCommandCallback());
  pCaptureChar->addDescriptor(new BLE2902());

  // Start the service
  pService->start();

  // Start advertising with scan response to ensure visibility on all platforms
  BLEAdvertising *pAdv = BLEDevice::getAdvertising();

  // Create advertisement data
  BLEAdvertisementData oAdvData = BLEAdvertisementData();
  oAdvData.setFlags(0x06); // General Discoverable, No BR/EDR
  oAdvData.setCompleteServices(BLEUUID(ICAN_EYE_SERVICE_UUID));
  oAdvData.setName("iCan Eye");
  pAdv->setAdvertisementData(oAdvData);

  // Create scan response data (some platforms look here for the name/UUID)
  BLEAdvertisementData oScanResponseData = BLEAdvertisementData();
  oScanResponseData.setCompleteServices(BLEUUID(ICAN_EYE_SERVICE_UUID));
  pAdv->setScanResponseData(oScanResponseData);

  pAdv->setScanResponse(true);
  pAdv->setMinPreferred(0x06);
  pAdv->setMaxPreferred(0x12);

  pAdv->start();

  Serial.println("[BLE] iCan Eye service advertising.");
}

// =========================================================================
// Public API — Connection & Commands
// =========================================================================

bool isBleEyeConnected() { return clientConnected; }

EyeCommandData getLastEyeCommand() {
  EyeCommandData cmd;
  portENTER_CRITICAL(&s_cmdMux);
  cmd.type = pendingCmdType;
  cmd.profileIndex = pendingCmdProfile;
  cmd.liveIntervalMs = pendingCmdLiveInterval;
  pendingCmdType = EYE_CMD_NONE;
  pendingCmdProfile = 0;
  pendingCmdLiveInterval = 0;
  portEXIT_CRITICAL(&s_cmdMux);
  return cmd;
}

// =========================================================================
// Notification — direct ESP-IDF call with return code + retry
// =========================================================================
//
// The Arduino BLE library's notify() returns void and silently drops
// notifications when the Bluedroid TX buffer is full (rc=-1).  We bypass
// it entirely and call esp_ble_gatts_send_indicate() using the gatts_if
// and conn_id captured in our custom GATTS event handler.  This gives us
// the actual return code so we can wait and retry on congestion.

static bool sendNotify(uint16_t attrHandle, const uint8_t *data, size_t len) {
  if (!clientConnected || s_gattsIf == 0) return false;

  const int maxRetries = 25;

  for (int attempt = 0; attempt < maxRetries; attempt++) {
    esp_err_t rc = esp_ble_gatts_send_indicate(
        s_gattsIf, s_connId, attrHandle,
        (uint16_t)len, (uint8_t *)data, false /* notification, not indication */);

    if (rc == ESP_OK) return true;

    if (!clientConnected) return false;

    // TX buffer full — yield to let the BLE controller drain it.
    // Longer waits on later attempts (2ms → 20ms) to handle Windows BLE
    // which drains slowly.
    int waitMs = (attempt < 5) ? 5 : (attempt < 15) ? 20 : 50;
    vTaskDelay(pdMS_TO_TICKS(waitMs));
  }

  return false;
}

// =========================================================================
// Public API — Control Messages
// =========================================================================

void sendControlMessage(const char *msg) {
  if (!clientConnected)
    return;
  if (!sendNotify(pCaptureChar->getHandle(),
                  (const uint8_t *)msg, strlen(msg))) {
    Serial.printf("[BLE] WARN: Control message lost: %s\n", msg);
  }
}

// =========================================================================
// Public API — Image Streaming
// =========================================================================

static uint32_t crc32(const uint8_t *data, size_t len) {
  uint32_t crc = 0xFFFFFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; bit++) {
      if (crc & 1) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc ^ 0xFFFFFFFF;
}

size_t sendImageChunk(uint16_t seqNum, const uint8_t *data, size_t dataLen) {
  if (!clientConnected)
    return 0;

  // Cap payload to negotiated MTU (ATT overhead = 3 bytes) and protocol max
  const size_t mtuPayload = (s_negotiatedMtu > 3 + IMAGE_HEADER_BYTES)
                                ? (s_negotiatedMtu - 3 - IMAGE_HEADER_BYTES)
                                : 0;
  const size_t effectiveMax = (mtuPayload < IMAGE_MAX_PAYLOAD) ? mtuPayload : IMAGE_MAX_PAYLOAD;
  if (dataLen > effectiveMax)
    dataLen = effectiveMax;
  if (dataLen == 0)
    return 0;

  uint8_t chunkBuf[IMAGE_MAX_PACKET_SIZE];

  // Pack header (2 bytes): sequence number (LE)
  chunkBuf[0] = (uint8_t)(seqNum & 0xFF);
  chunkBuf[1] = (uint8_t)((seqNum >> 8) & 0xFF);

  // Copy payload
  memcpy(chunkBuf + IMAGE_HEADER_BYTES, data, dataLen);

  if (!sendNotify(pImageStreamChar->getHandle(),
                  chunkBuf, IMAGE_HEADER_BYTES + dataLen)) {
    Serial.printf("[BLE] FAILED chunk %u after retries\n", seqNum);
    return 0;
  }

  // Inter-chunk pacing: yield to BLE task so notifications get flushed.
  // Every 10 chunks, add a longer drain pause for the remote BLE stack.
  if (seqNum > 0 && seqNum % 10 == 0) {
    vTaskDelay(pdMS_TO_TICKS(25));
  } else {
    vTaskDelay(pdMS_TO_TICKS(8));
  }
  return dataLen;
}

void streamImageViaBle(const uint8_t *jpegBuf, size_t jpegLen,
                       const char *profileName) {
  if (!clientConnected)
    return;

  // Effective max payload per chunk (for logging)
  const size_t mtuPayload = (s_negotiatedMtu > 3 + IMAGE_HEADER_BYTES)
                                ? (s_negotiatedMtu - 3 - IMAGE_HEADER_BYTES)
                                : 0;
  const size_t effectiveMax = (mtuPayload < IMAGE_MAX_PAYLOAD) ? mtuPayload : IMAGE_MAX_PAYLOAD;
  if (effectiveMax == 0) {
    char abortMsg[64];
    snprintf(abortMsg, sizeof(abortMsg), "ERR:STREAM_ABORTED:0:0:%u",
             (unsigned)jpegLen);
    sendControlMessage(abortMsg);
    Serial.printf("[BLE] Cannot stream image: MTU=%u gives 0 payload bytes\n",
                  s_negotiatedMtu);
    return;
  }
  const unsigned estChunks = (jpegLen + effectiveMax - 1) / effectiveMax;

  Serial.printf("[BLE] Streaming %u bytes (MTU=%u, payload=%u, ~%u chunks, profile=%s)\n",
                (unsigned)jpegLen, s_negotiatedMtu, (unsigned)effectiveMax,
                estChunks, profileName);

  // 1. Send SIZE
  char ctrlMsg[32];
  snprintf(ctrlMsg, sizeof(ctrlMsg), "SIZE:%u", (unsigned)jpegLen);
  sendControlMessage(ctrlMsg);
  vTaskDelay(pdMS_TO_TICKS(30)); // Let client process SIZE before chunks arrive

  const uint32_t crc = crc32(jpegBuf, jpegLen);
  snprintf(ctrlMsg, sizeof(ctrlMsg), "CRC:%08X", (unsigned)crc);
  sendControlMessage(ctrlMsg);
  vTaskDelay(pdMS_TO_TICKS(20));

  // 2. Stream image chunks with retry on failure
  const unsigned long startMs = millis();
  uint16_t seqNum = 0;
  size_t offset = 0;
  int consecutiveFails = 0;
  bool aborted = false;

  while (offset < jpegLen) {
    if (!isBleEyeConnected()) {
      Serial.println("[BLE] Client disconnected mid-stream — aborting.");
      return;
    }
    size_t remaining = jpegLen - offset;
    size_t sent = sendImageChunk(seqNum, jpegBuf + offset, remaining);
    if (sent == 0) {
      consecutiveFails++;
      if (consecutiveFails > 3) {
        Serial.printf("[BLE] %d consecutive failures — aborting stream.\n",
                      consecutiveFails);
        snprintf(ctrlMsg, sizeof(ctrlMsg), "ERR:CHUNK_NOTIFY_FAILED:%u",
                 seqNum);
        sendControlMessage(ctrlMsg);
        aborted = true;
        break;
      }
      // Wait and retry the SAME chunk — don't skip data
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    consecutiveFails = 0;
    offset += sent;
    seqNum++;
    if (seqNum % 20 == 0) {
      Serial.printf("[BLE] Progress: chunk %u, %u/%u bytes (%.0f%%)\n",
                    seqNum, (unsigned)offset, (unsigned)jpegLen,
                    offset * 100.0 / jpegLen);
    }
  }

  const unsigned long elapsed = millis() - startMs;

  if (aborted || offset < jpegLen) {
    char abortMsg[64];
    snprintf(abortMsg, sizeof(abortMsg), "ERR:STREAM_ABORTED:%u:%u:%u",
             seqNum, (unsigned)offset, (unsigned)jpegLen);
    sendControlMessage(abortMsg);
    Serial.printf("[BLE] Stream aborted: %u chunks, %u/%u bytes\n",
                  seqNum, (unsigned)offset, (unsigned)jpegLen);
    return;
  }

  // 3. Send END — repeated 3× with gaps to survive BLE notification loss
  vTaskDelay(pdMS_TO_TICKS(30));
  snprintf(ctrlMsg, sizeof(ctrlMsg), "END:%u", seqNum);
  for (int i = 0; i < 3; i++) {
    sendControlMessage(ctrlMsg);
    if (i < 2) vTaskDelay(pdMS_TO_TICKS(50));
  }

  const float kbps = (elapsed > 0) ? (jpegLen / 1024.0f) / (elapsed / 1000.0f) : 0;
  Serial.printf("[BLE] Transfer complete: %u chunks, %u bytes in %lu ms "
                "(%.1f KB/s, %d retried)\n",
                seqNum, (unsigned)offset, elapsed, kbps, consecutiveFails);
}
