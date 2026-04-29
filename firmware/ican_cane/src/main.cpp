/**
 * ============================================================================
 * iCan Cane — Main Firmware Entry Point
 * Target: Arduino Nano ESP32
 * ============================================================================
 *
 * This skeleton initializes all subsystems and runs the main loop.
 * Each subsystem is modular — see lib/ for individual driver wrappers.
 *
 * Subsystems:
 *   - I²C Bus 0 (Wire,  A4/A5): PCA9548A MUX → DRV2605L haptics
 *   - I²C Bus 1 (Wire1, D6/D7): DFRobot SEN0628 Matrix LiDAR + LSM6DSOX IMU (direct)
 *   - Sensors: SEN0628 Matrix LiDAR, 2x Ultrasonic, LSM6DSOX IMU
 *   - Haptics: DRV2605L via I²C mux on Bus 0
 *   - BLE: NimBLE peripheral (receives nav commands, sends telemetry)
 *   - GPS: Adafruit Mini GPS (future — Guided Nav)
 * ============================================================================
 */

#include "ble_protocol.h"
#include <Arduino.h>
#include <Wire.h>

// Local library headers (implemented in lib/ subdirectories)
#include "ble_comm.h"
#include "gps.h"
#include "haptics.h"
#include "sensors.h"

// The esp32dev PlatformIO board does not expose Arduino Nano-style D6/D7
// aliases. Keep the documented secondary I2C wiring compiling for both
// environments.
#ifndef D6
#define D6 9
#endif
#ifndef D7
#define D7 10
#endif

// ---------------------------------------------------------------------------
// Pin Definitions
// ---------------------------------------------------------------------------
constexpr uint8_t PIN_ULTRASONIC_LEFT_TRIG = 2;
constexpr uint8_t PIN_ULTRASONIC_LEFT_ECHO = 3;
constexpr uint8_t PIN_ULTRASONIC_RIGHT_TRIG = 4;
constexpr uint8_t PIN_ULTRASONIC_RIGHT_ECHO = 5;

// I²C Mux address (TCA9548A default)
constexpr uint8_t I2C_MUX_ADDR = 0x70;

// I²C Mux channel assignments
constexpr uint8_t MUX_CH_DRV2605 = 0; // Haptic driver
constexpr uint8_t MUX_CH_LIDAR = 1;   // TF Luna LiDAR
constexpr uint8_t MUX_CH_IMU = 2;     // LSM6DSOX

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------
constexpr unsigned long SENSOR_POLL_INTERVAL_MS = 50;     // 20 Hz
constexpr unsigned long TELEMETRY_SEND_INTERVAL_MS = 200; // 5 Hz
constexpr unsigned long GPS_SEND_INTERVAL_MS = 1000;      // 1 Hz

unsigned long lastSensorPoll = 0;
unsigned long lastTelemetrySend = 0;
unsigned long lastGpsSend = 0;

// ---------------------------------------------------------------------------
// I²C Mux Helper
// ---------------------------------------------------------------------------
void selectMuxChannel(uint8_t channel) {
  Wire.beginTransmission(I2C_MUX_ADDR);
  Wire.write(1 << channel);
  Wire.endTransmission();
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.println("[iCan Cane] Booting...");

  // Initialize I²C buses
  Wire.begin();        // Bus 0 (A4/A5) — MUX only → DRV2605L haptics
  Wire1.begin(D6, D7); // Bus 1 (D6=SDA, D7=SCL) — SEN0628 LiDAR + LSM6DSOX IMU

  // Initialize subsystems
  selectMuxChannel(MUX_CH_DRV2605);
  initHaptics();

  initSensors(PIN_ULTRASONIC_LEFT_TRIG, PIN_ULTRASONIC_LEFT_ECHO,
              PIN_ULTRASONIC_RIGHT_TRIG, PIN_ULTRASONIC_RIGHT_ECHO);

  // Pulse sensor on A0 — 3.3V analog, non-blocking 500Hz polling
  initPulseSensor(A0);

  initBleCane();
  initGPS();

  Serial.println("[iCan Cane] Fall thresholds: LOW-G < 5.0 m/s2, IMPACT > 20 m/s2");

  Serial.println("[iCan Cane] Ready.");
}

// ---------------------------------------------------------------------------
// Main Loop
// ---------------------------------------------------------------------------
void loop() {
  unsigned long now = millis();

  // --- Update pulse sensor at 500 Hz (must run every loop, uses micros()) ---
  updatePulseSensor();

  // --- Poll GPS every iteration (non-blocking, must run every loop) ---
  pollGPS();

  // --- Poll sensors at fixed interval ---
  if (now - lastSensorPoll >= SENSOR_POLL_INTERVAL_MS) {
    lastSensorPoll = now;

    // Read ultrasonic distances
    float distLeft = readUltrasonicLeft();
    float distRight = readUltrasonicRight();

    // Read LiDAR (head-height) — SEN0628 on Wire1, no mux needed
    float distHead = readLidar();

    // Read IMU — LSM6DSOX on Wire1, no mux needed
    ImuData imu = readIMU();

    // --- Free Nav: Obstacle detection → Haptic feedback ---
    // TODO (Task 4.1): Integrate IMU sweep logic here
    constexpr float OBSTACLE_THRESHOLD_CM = 80.0f;

    if (distHead < OBSTACLE_THRESHOLD_CM && distHead > 0) {
      selectMuxChannel(MUX_CH_DRV2605);
      playPattern(PATTERN_OBSTACLE_HEAD);
      notifyObstacle(OBSTACLE_HEAD, static_cast<uint16_t>(distHead));
    }
    if (distLeft < OBSTACLE_THRESHOLD_CM && distLeft > 0) {
      selectMuxChannel(MUX_CH_DRV2605);
      playPattern(PATTERN_OBSTACLE_LEFT);
      notifyObstacle(OBSTACLE_LEFT, static_cast<uint16_t>(distLeft));
    }
    if (distRight < OBSTACLE_THRESHOLD_CM && distRight > 0) {
      selectMuxChannel(MUX_CH_DRV2605);
      playPattern(PATTERN_OBSTACLE_RIGHT);
      notifyObstacle(OBSTACLE_RIGHT, static_cast<uint16_t>(distRight));
    }

    // --- Guided Nav: Process incoming BLE nav commands ---
    NavCommand pendingNav = getLastNavCommand();
    if (pendingNav != NAV_STOP) {
      selectMuxChannel(MUX_CH_DRV2605);
      // TODO (Task 4.2): Prioritize obstacle vs nav
      switch (pendingNav) {
      case NAV_TURN_LEFT:
        playPattern(PATTERN_NAV_LEFT);
        break;
      case NAV_TURN_RIGHT:
        playPattern(PATTERN_NAV_RIGHT);
        break;
      case NAV_GO_STRAIGHT:
        playPattern(PATTERN_NAV_STRAIGHT);
        break;
      case NAV_ARRIVED:
        playPattern(PATTERN_ARRIVED);
        break;
      default:
        break;
      }
    }
  }

  // --- Send telemetry at fixed interval ---
  if (now - lastTelemetrySend >= TELEMETRY_SEND_INTERVAL_MS) {
    lastTelemetrySend = now;

    ImuData imu = readIMU();

    TelemetryPacket pkt = {};

    // Heart rate
    PulseData pulse = getPulseData();
    pkt.pulse_bpm = pulse.bpm;
    if (pulse.valid) pkt.flags |= 0x02;

    // Fall detection — set flag and trigger haptic on active fall
    if (imu.fallDetected) {
      pkt.flags |= 0x01;
      selectMuxChannel(MUX_CH_DRV2605);
      playPattern(PATTERN_FALL_ALERT); // rapid triple buzz
    }

    pkt.battery_percent = 100; // TODO: read actual battery ADC
    pkt.yaw_angle = static_cast<int16_t>(imu.yaw * 10);

    Serial.printf("[Telemetry] fall=%d hr=%d(%s) bat=%d yaw=%.1f\n",
      imu.fallDetected, pulse.bpm, pulse.valid ? "valid" : "no-signal",
      pkt.battery_percent, imu.yaw);

    sendTelemetry(pkt);
  }

  // --- Send GPS data at 1 Hz ---
  if (now - lastGpsSend >= GPS_SEND_INTERVAL_MS) {
    lastGpsSend = now;
    sendGpsData(getGPSData());
  }
}
