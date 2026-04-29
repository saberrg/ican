/**
 * sensors.cpp — Unified Sensor Implementation
 */

#include "sensors.h"
#include <Adafruit_LSM6DSOX.h>
#include <Arduino.h>
#include <DFRobot_MatrixLidar.h>
#define USE_ARDUINO_INTERRUPTS false
#include <PulseSensorPlayground.h>
#include <Wire.h>

#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------
static uint8_t pinLeftTrig, pinLeftEcho;
static uint8_t pinRightTrig, pinRightEcho;
static Adafruit_LSM6DSOX imu;
static bool imuReady = false;

// DFRobot SEN0628 Matrix LiDAR on Wire1 (D6=SDA, D7=SCL), default addr 0x33
static DFRobot_MatrixLidar_I2C matrixLidar(0x33, &Wire1);
static bool lidarReady = false;

// ---------------------------------------------------------------------------
// Fall detection — two-phase state machine
// Phase 1: FREE_FALL — accel magnitude drops below FREE_FALL_G for ≥80ms
// Phase 2: IMPACT    — accel magnitude spikes above IMPACT_G within 500ms
// Phase 3: CONFIRMED — hold fallDetected=true for FALL_HOLD_MS then reset
// ---------------------------------------------------------------------------
constexpr float FREE_FALL_G   = 5.0f;    // m/s² (≈0.5g) — low-G entry threshold
constexpr float IMPACT_G      = 20.0f;   // m/s² (≈2g)   — impact entry threshold
constexpr unsigned long FREE_FALL_MIN_MS = 80;    // must stay low-G for 80ms
constexpr unsigned long IMPACT_WINDOW_MS = 500;   // impact must follow within 500ms
constexpr unsigned long FALL_HOLD_MS     = 10000; // hold fall alert for 10 seconds

enum FallState { FALL_IDLE, FALL_FREE_FALL, FALL_IMPACT, FALL_CONFIRMED };
static FallState fallState = FALL_IDLE;
static unsigned long fallStateEnteredMs = 0;  // millis() when we entered current state
static bool fallDetectedGlobal = false;

// ---------------------------------------------------------------------------
// Ultrasonic helper
// ---------------------------------------------------------------------------
static float readUltrasonic(uint8_t trigPin, uint8_t echoPin) {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);
  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);
  digitalWrite(trigPin, LOW);

  unsigned long duration = pulseIn(echoPin, HIGH, 30000); // 30ms timeout
  if (duration == 0)
    return -1.0f;

  // Speed of sound ≈ 0.0343 cm/µs, round-trip → divide by 2
  return (duration * 0.0343f) / 2.0f;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void initSensors(uint8_t leftTrig, uint8_t leftEcho, uint8_t rightTrig,
                 uint8_t rightEcho) {
  // Ultrasonic pins
  pinLeftTrig = leftTrig;
  pinLeftEcho = leftEcho;
  pinRightTrig = rightTrig;
  pinRightEcho = rightEcho;

  pinMode(pinLeftTrig, OUTPUT);
  pinMode(pinLeftEcho, INPUT);
  pinMode(pinRightTrig, OUTPUT);
  pinMode(pinRightEcho, INPUT);

  Serial.println("[Sensors] Ultrasonic pins configured.");

  // LiDAR init on Wire1
  if (matrixLidar.begin() == 0) {
    lidarReady = true;
    Serial.println("[Sensors] SEN0628 Matrix LiDAR initialized.");
  } else {
    Serial.println("[Sensors] WARNING: SEN0628 Matrix LiDAR not found.");
  }

  // IMU init on Wire1 (D6=SDA, D7=SCL)
  if (imu.begin_I2C(LSM6DS_I2CADDR_DEFAULT, &Wire1)) {
    imuReady = true;
    imu.setAccelRange(LSM6DS_ACCEL_RANGE_4_G);
    imu.setGyroRange(LSM6DS_GYRO_RANGE_250_DPS);
    imu.setAccelDataRate(LSM6DS_RATE_104_HZ);
    imu.setGyroDataRate(LSM6DS_RATE_104_HZ);
    Serial.println("[Sensors] LSM6DSOX IMU initialized.");
  } else {
    Serial.println("[Sensors] WARNING: LSM6DSOX not found.");
  }

  Serial.println("[Sensors] Init complete.");
}

float readUltrasonicLeft() { return readUltrasonic(pinLeftTrig, pinLeftEcho); }

float readUltrasonicRight() {
  return readUltrasonic(pinRightTrig, pinRightEcho);
}

float readLidar() {
  if (!lidarReady)
    return -1.0f;

  // SEN0628 returns an 8x8 grid of distances in mm.
  // Scan all 64 points and return the minimum (closest obstacle) in cm.
  uint16_t minMm = 0xFFFF;
  for (uint8_t x = 0; x < 8; x++) {
    for (uint8_t y = 0; y < 8; y++) {
      uint16_t d = matrixLidar.getFixedPointData(x, y);
      if (d > 0 && d < minMm)
        minMm = d;
    }
  }

  if (minMm == 0xFFFF)
    return -1.0f;

  return minMm / 10.0f; // mm → cm
}

// ===========================================================================
// Pulse Sensor — PulseSensor Playground library v1.x (polling mode)
// USE_ARDUINO_INTERRUPTS=false is defined before the PulseSensor header in
// this translation unit only; the library requires it not be global.
// Hardware: PulseSensor Amped, 3.3V, analog pin A0 on Nano ESP32.
// Threshold 2000 matches verified standalone firmware for this sensor.
// ===========================================================================

static PulseSensorPlayground pulseSensor;
static PulseData pulseResult          = {0, false};
static unsigned long pulseLastBeatMs  = 0;
static unsigned long pulseLastDebugMs = 0;
constexpr unsigned long PULSE_STALE_MS = 3000; // invalidate if no beat for 3s

void initPulseSensor(uint8_t pin) {
  pulseSensor.analogInput(pin);
  pulseSensor.blinkOnPulse(LED_BUILTIN); // built-in LED flashes on each beat
  pulseSensor.setThreshold(2000);        // tuned for ESP32 ADC, matches standalone firmware

  if (pulseSensor.begin()) {
    Serial.printf("[HR] PulseSensor Playground ready on A0, threshold=2000\n");
  } else {
    Serial.println("[HR] WARNING: PulseSensor.begin() failed — check wiring");
  }
}

void updatePulseSensor() {
  // In polling mode (USE_ARDUINO_INTERRUPTS=false), sawStartOfBeat() drives
  // the library's internal 2ms sampling — must be called every loop().
  if (pulseSensor.sawStartOfBeat()) {
    int bpm = pulseSensor.getBeatsPerMinute();
    pulseLastBeatMs = millis();

    if (bpm >= 40 && bpm <= 200) {
      pulseResult.bpm   = (uint8_t)bpm;
      pulseResult.valid = true;
    }
    Serial.printf("[HR] Beat! BPM: %d\n", bpm);
  }

  // Clear if no beat for 3s (sensor removed / no contact)
  if (pulseResult.valid && (millis() - pulseLastBeatMs) > PULSE_STALE_MS) {
    pulseResult.bpm   = 0;
    pulseResult.valid = false;
    Serial.println("[HR] Signal lost — no beat for 3s");
  }

  // Status log every 2s
  unsigned long now = millis();
  if ((now - pulseLastDebugMs) >= 2000) {
    pulseLastDebugMs = now;
    Serial.printf("[HR] BPM: %d  Valid: %s  Signal: %d\n",
      pulseResult.bpm,
      pulseResult.valid ? "YES" : "NO",
      pulseSensor.getLatestSample());
  }
}

PulseData getPulseData() {
  return pulseResult;
}

// ===========================================================================

ImuData readIMU() {
  ImuData data = {};
  if (!imuReady)
    return data;

  sensors_event_t accel, gyro, temp;
  imu.getEvent(&accel, &gyro, &temp);

  data.accelX = accel.acceleration.x;
  data.accelY = accel.acceleration.y;
  data.accelZ = accel.acceleration.z;
  data.gyroX = gyro.gyro.x;
  data.gyroY = gyro.gyro.y;
  data.gyroZ = gyro.gyro.z;

  // Simple yaw estimation from gyro Z integration (placeholder)
  // TODO (Task 4.1): Replace with proper complementary/Madgwick filter
  static float yawAccum = 0.0f;
  yawAccum += data.gyroZ * 0.05f; // dt ≈ 50ms
  data.yaw = yawAccum;

  // Fall detection — two-phase state machine
  // Use squared comparisons to avoid sqrt() (problematic on Windows builds)
  float accelMagSq = (data.accelX * data.accelX) +
                     (data.accelY * data.accelY) +
                     (data.accelZ * data.accelZ);
  unsigned long now = millis();

  switch (fallState) {
    case FALL_IDLE:
      if (accelMagSq < (FREE_FALL_G * FREE_FALL_G)) {
        fallState = FALL_FREE_FALL;
        fallStateEnteredMs = now;
        Serial.printf("[FALL] IDLE → FREE_FALL (accelMagSq=%.2f)\n", accelMagSq);
      }
      break;

    case FALL_FREE_FALL:
      if (accelMagSq >= (FREE_FALL_G * FREE_FALL_G)) {
        // Left low-G zone without enough duration — reset
        if ((now - fallStateEnteredMs) < FREE_FALL_MIN_MS) {
          fallState = FALL_IDLE;
          Serial.println("[FALL] FREE_FALL → IDLE (too short)");
          break;
        }
        // Stayed in low-G long enough — now watch for impact
        fallState = FALL_IMPACT;
        fallStateEnteredMs = now;
        Serial.printf("[FALL] FREE_FALL → IMPACT (window open, accelMagSq=%.2f)\n", accelMagSq);
      } else if ((now - fallStateEnteredMs) > IMPACT_WINDOW_MS) {
        // Stayed low-G too long (device just lying still?) — reset
        fallState = FALL_IDLE;
        Serial.println("[FALL] FREE_FALL → IDLE (timeout, no impact)");
      }
      break;

    case FALL_IMPACT:
      if (accelMagSq > (IMPACT_G * IMPACT_G)) {
        // Impact detected → confirmed fall
        fallState = FALL_CONFIRMED;
        fallStateEnteredMs = now;
        fallDetectedGlobal = true;
        Serial.printf("[FALL] IMPACT → CONFIRMED (accelMagSq=%.2f) — FALL ALERT!\n", accelMagSq);
      } else if ((now - fallStateEnteredMs) > IMPACT_WINDOW_MS) {
        // No impact within window — false alarm
        fallState = FALL_IDLE;
        Serial.println("[FALL] IMPACT → IDLE (no impact in window)");
      }
      break;

    case FALL_CONFIRMED:
      if ((now - fallStateEnteredMs) >= FALL_HOLD_MS) {
        fallState = FALL_IDLE;
        fallDetectedGlobal = false;
        Serial.println("[FALL] CONFIRMED → IDLE (hold expired)");
      }
      break;
  }

  data.fallDetected = fallDetectedGlobal;

  return data;
}
