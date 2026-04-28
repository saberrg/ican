/**
 * ============================================================================
 * iCan Eye — Main Firmware Entry Point
 * Target: Seeed XIAO ESP32-S3 Sense
 * ============================================================================
 *
 * Initializes the camera and BLE subsystems, then waits for commands from a
 * connected BLE client (phone or computer).
 *
 * Subsystems (see lib/ for individual module implementations):
 *   - Camera: XIAO Sense camera via esp_camera, profile-based JPEG capture
 *   - BLE: ESP32 BLE peripheral using shared iCan Eye service UUIDs
 *
 * ============================================================================
 */

#include <Arduino.h>

// Local library headers (implemented in lib/ subdirectories)
#include "ble_eye.h"
#include "camera.h"

// Shared protocol (included via -I../../shared build flag)
#include "ble_protocol.h"

// Hardware Button Configuration
#define CAPTURE_BUTTON_PIN D1
static const char *ICAN_EYE_FIRMWARE_VERSION = "1.0.0+25";
const unsigned long BUTTON_DEBOUNCE_MS = 50;
const unsigned long DOUBLE_PRESS_WINDOW_MS = 400;

enum ButtonState : uint8_t {
  BTN_IDLE,
  BTN_FIRST_DOWN,
  BTN_WAITING_SECOND,
  BTN_SECOND_DOWN,
};

ButtonState buttonState = BTN_IDLE;
unsigned long buttonDownTime = 0;
unsigned long buttonUpTime = 0;
bool lastButtonReading = HIGH;

// Live capture mode state
bool liveMode = false;
int liveIntervalMs = 1500;
unsigned long lastLiveCaptureMs = 0;

// ============================================================================
// Setup
// ============================================================================

void setup() {
  // Use built-in LED (Pin 21) for diagnostics
  pinMode(21, OUTPUT);
  digitalWrite(21, LOW); // LED ON: Boot started

  Serial.begin(115200);

  uint32_t t = millis();
  while (!Serial && (millis() - t < 5000)) {
      delay(10);
  }
  delay(1000);

  Serial.println("\n\n=== iCan Eye Firmware ===");

  // Initialize physical button
  pinMode(CAPTURE_BUTTON_PIN, INPUT_PULLUP);

  // Initialize subsystems
  initCamera();
  
  // Quick blink before BLE init
  digitalWrite(21, HIGH); delay(100);
  digitalWrite(21, LOW); delay(100);

  initBleEye();

  // LED OFF: Successfully reached loop()
  digitalWrite(21, HIGH);

  Serial.printf("[Main] Default profile: %d (%s)\n", getCurrentProfile(),
                profiles[getCurrentProfile()].name);
  Serial.println("[Main] Ready — waiting for BLE connection...");
}

// ============================================================================
// Main Loop
// ============================================================================

void loop() {
  // Button state machine: single press = capture, double press = voice command
  bool reading = digitalRead(CAPTURE_BUTTON_PIN);
  unsigned long now = millis();

  switch (buttonState) {
  case BTN_IDLE:
    if (reading == LOW && lastButtonReading == HIGH &&
        (now - buttonUpTime) > BUTTON_DEBOUNCE_MS) {
      buttonState = BTN_FIRST_DOWN;
      buttonDownTime = now;
    }
    break;

  case BTN_FIRST_DOWN:
    if (reading == HIGH && lastButtonReading == LOW &&
        (now - buttonDownTime) > BUTTON_DEBOUNCE_MS) {
      buttonState = BTN_WAITING_SECOND;
      buttonUpTime = now;
    }
    break;

  case BTN_WAITING_SECOND:
    if (reading == LOW && lastButtonReading == HIGH &&
        (now - buttonUpTime) > BUTTON_DEBOUNCE_MS) {
      buttonState = BTN_SECOND_DOWN;
      buttonDownTime = now;
    } else if (now - buttonUpTime > DOUBLE_PRESS_WINDOW_MS) {
      // Timeout — single press: trigger capture
      buttonState = BTN_IDLE;
      Serial.println("[Main] Single press — triggering capture.");
      digitalWrite(21, LOW); delay(50);
      digitalWrite(21, HIGH); delay(50);
      digitalWrite(21, LOW); delay(50);
      digitalWrite(21, HIGH);
      if (!isBleEyeConnected()) {
        Serial.println("[Main] No client connected.");
      } else {
        camera_fb_t *fb = capturePhoto();
        if (fb) {
          streamImageViaBle(fb->buf, fb->len,
                            profiles[getCurrentProfile()].name);
          esp_camera_fb_return(fb);
        }
      }
    }
    break;

  case BTN_SECOND_DOWN:
    if (reading == HIGH && lastButtonReading == LOW &&
        (now - buttonDownTime) > BUTTON_DEBOUNCE_MS) {
      // Double press detected — send voice trigger event
      buttonState = BTN_IDLE;
      buttonUpTime = now;
      Serial.println("[Main] Double press — sending BUTTON:DOUBLE.");
      // Triple blink for distinct feedback
      for (int i = 0; i < 3; i++) {
        digitalWrite(21, LOW); delay(40);
        digitalWrite(21, HIGH); delay(40);
      }
      if (isBleEyeConnected()) {
        sendControlMessage("BUTTON:DOUBLE");
      }
    }
    break;
  }

  lastButtonReading = reading;

  // Stop live mode if client disconnected
  if (liveMode && !isBleEyeConnected()) {
    liveMode = false;
    Serial.println("[Main] Client disconnected — live mode stopped.");
  }

  // Check for pending BLE commands
  EyeCommandData cmd = getLastEyeCommand();

  switch (cmd.type) {
  case EYE_CMD_CAPTURE: {
    if (!isBleEyeConnected()) {
      Serial.println("[Main] Capture requested but no client connected.");
      break;
    }
    sendControlMessage("CAPTURE:START");
    camera_fb_t *fb = capturePhoto();
    if (fb) {
      streamImageViaBle(fb->buf, fb->len,
                        profiles[getCurrentProfile()].name);
      esp_camera_fb_return(fb);
    } else {
      sendControlMessage("ERR:CAMERA_CAPTURE_FAILED");
    }
    break;
  }

  case EYE_CMD_LIVE_START: {
    liveMode = true;
    liveIntervalMs = cmd.liveIntervalMs;
    lastLiveCaptureMs = 0;
    Serial.printf("[Main] Live mode ON — interval %dms\n", liveIntervalMs);
    sendControlMessage("LIVE_STARTED");
    break;
  }

  case EYE_CMD_LIVE_STOP: {
    liveMode = false;
    Serial.println("[Main] Live mode OFF");
    sendControlMessage("LIVE_STOPPED");
    break;
  }

  case EYE_CMD_PROFILE: {
    if (cmd.profileIndex >= 0 && cmd.profileIndex < NUM_PROFILES) {
      applyProfile(cmd.profileIndex);
      char msg[64];
      snprintf(msg, sizeof(msg), "PROFILE_SET:%d:%s", cmd.profileIndex,
               profiles[cmd.profileIndex].name);
      sendControlMessage(msg);
    } else {
      Serial.printf("[Main] Invalid profile index: %d\n", cmd.profileIndex);
    }
    break;
  }

  case EYE_CMD_STATUS:
    Serial.printf("[Main] Current profile: %d (%s), live=%s\n",
                  getCurrentProfile(), profiles[getCurrentProfile()].name,
                  liveMode ? "ON" : "OFF");
    {
      char msg[96];
      snprintf(msg, sizeof(msg), "STATUS:%d:%s:%s:%d:%s", getCurrentProfile(),
               profiles[getCurrentProfile()].name, liveMode ? "LIVE" : "IDLE",
               liveIntervalMs, ICAN_EYE_FIRMWARE_VERSION);
      sendControlMessage(msg);
    }
    break;

  case EYE_CMD_NONE:
  default:
    break;
  }

  // Firmware-driven live capture: auto-capture at the requested interval
  if (liveMode && isBleEyeConnected()) {
    unsigned long now = millis();
    if (now - lastLiveCaptureMs >= (unsigned long)liveIntervalMs) {
      lastLiveCaptureMs = now;
      sendControlMessage("CAPTURE:START");
      camera_fb_t *fb = capturePhoto();
      if (fb) {
        streamImageViaBle(fb->buf, fb->len,
                          profiles[getCurrentProfile()].name);
        esp_camera_fb_return(fb);
      } else {
        sendControlMessage("ERR:CAMERA_CAPTURE_FAILED");
      }
    }
  }

  delay(10);
}
