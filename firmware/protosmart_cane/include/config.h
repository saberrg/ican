/*
 * ProtoSmartCane - Centralized Configuration
 * All tuning parameters, constants, and hardware definitions
 */

#pragma once

// === HARDWARE PIN DEFINITIONS (GPIO MODE) ===
// BOARD_USES_HW_GPIO_NUMBERS is enabled in platformio.ini.
// Values below are raw ESP32-S3 GPIO numbers, mapped to same Nano header locations.
#define HAPTIC_DISK_PIN 45     // Center vibration disk motor (legacy name: BUZZER_PIN)
#define BUZZER_PIN HAPTIC_DISK_PIN
#define LED_PIN -1             // Legacy LED disabled
#define LED_HEAD_PIN 47        // Nano D12
#define LED_LEFT_PIN 48        // Nano D13
#define LED_RIGHT_PIN 46       // Nano LED_RED pin location (previous pin ID 14)
#define LED_HAPTIC_HEAD_PIN 18   // Nano D9
#define LED_HAPTIC_LEFT_PIN 21   // Nano D10
#define LED_HAPTIC_RIGHT_PIN 38  // Nano D11
#define HAPTIC_HEAD_PIN LED_HAPTIC_HEAD_PIN
#define HAPTIC_LEFT_PIN LED_HAPTIC_LEFT_PIN
#define HAPTIC_RIGHT_PIN LED_HAPTIC_RIGHT_PIN
#define BATTERY_PIN 2          // Nano A1
#define HEART_PIN 1            // Nano A0
#define PULSE_LED 25           // Raw GPIO25 (optional pulse blink)
#define LOW_BATTERY_PIN 17     // Nano D8

// === SPI / I2C BUS PINS (GPIO MODE) ===
#define I2C_SDA_PIN 11         // Nano A4 / SDA
#define I2C_SCL_PIN 12         // Nano A5 / SCL

// === ULTRASONIC PIN DEFINITIONS (GPIO MODE) ===
#define ULTRASONIC_LEFT_ECHO_PIN 7   // Nano D4
#define ULTRASONIC_LEFT_TRIG_PIN 8   // Nano D5
#define ULTRASONIC_RIGHT_ECHO_PIN 5  // Nano D2
#define ULTRASONIC_RIGHT_TRIG_PIN 6  // Nano D3

// === I2C2 BUS PINS (GPIO MODE) ===
#define I2C2_SDA_PIN 9          // Nano D6
#define I2C2_SCL_PIN 10         // Nano D7 for 8x8 sensor and IMU
#define BATTERY_R1 10000.0f    // Voltage divider resistor 1 (10k)
#define BATTERY_R2 3300.0f     // Voltage divider resistor 2 (3.3k)
#define BATTERY_VREF 3.3f      // ESP32 ADC reference voltage
#define BATTERY_MAX_V 4.2f     // LiPo max voltage
#define BATTERY_MIN_V 3.0f     // LiPo min voltage
#define BATTERY_LOW_THRESHOLD 20   // % - trigger low power mode
#define BATTERY_RECOVERY_THRESHOLD 30  // % - return to normal mode

// === I2C ADDRESSES ===
#define MUX_ADDR 0x70              // PCA9548A I2C multiplexer
#define MATRIX_SENSOR_I2C_ADDR 0x33        // 8x8 matrix sensor on secondary I2C bus
#define IMU_I2C_ADDR 0x6A          // LSM6DSOX IMU (primary address)

// === MUX CHANNEL ASSIGNMENTS ===
// I2C Mux channels for primary I2C bus (3 DRV2605 haptic drivers)
#define HAPTIC_LEFT_CHANNEL 3    // Left haptic driver
#define HAPTIC_HEAD_CHANNEL 1    // Head haptic driver
#define HAPTIC_RIGHT_CHANNEL 2   // Right haptic driver
#define LIGHT_CHANNEL 4                    // Ambient light sensor

// Secondary I2C bus (IMU + 8x8 sensor on GPIO9/10)
#define MATRIX_SENSOR_CHANNEL 0
#define IMU_CHANNEL 2

// === 8x8 MATRIX SENSOR CONFIGURATION ===
#define MATRIX_SENSOR_MAX_DISTANCE_MM 1500  // mm - ignore far readings beyond useful range
#define MATRIX_SENSOR_ZONE_THRESHOLD_MM 1500 // mm - use this for far obstacle classification
#define MATRIX_SENSOR_INIT_RETRY_DELAY_MS 200 // keep failed recovery attempts responsive

// === FALL DETECTION PARAMETERS ===
// Matches ReferencedLogic/Arduino Codes/fall_detection/fall_detection.ino.
#define FALL_FREEFALL_THRESHOLD_G 0.5f   // g - start of free fall
#define FALL_IMPACT_THRESHOLD_G 2.5f     // g - impact detection
#define FALL_GYRO_THRESHOLD_DPS 180.0f   // deg/s - rotation during impact
#define FALL_IMPACT_WINDOW 500           // ms - max time between freefall and impact
#define FALL_INACTIVITY_TIMEOUT 2000     // ms - inactivity detection
#define FALL_COOLDOWN 2000               // ms - prevent fall spam detection
#define FALL_FLAG_HOLD_MS 2000           // ms - keep BLE fall flag high after detection

// === OBSTACLE DETECTION THRESHOLDS ===
#define OBSTACLE_FAR_MM 1500             // mm - far obstacle detection
#define OBSTACLE_NEAR_MM 500             // mm - near obstacle warning
#define OBSTACLE_IMMINENT_MM 200         // mm - imminent collision alert

// === ULTRASONIC CONFIGURATION ===
#define NUM_ULTRASONIC_SENSORS 2         // Number of ultrasonic sensors
#define ULTRASONIC_MAX_RANGE_MM 1500     // Experimental feedback range
#define ULTRASONIC_TIMEOUT_US 13000      // Echo timeout; keeps left/right reads responsive

// === HEART RATE MONITORING ===
#define HEART_THRESHOLD 2000             // PulseSensor threshold
#define HEART_ABNORMAL_HIGH_BPM 120      // High heart rate threshold
#define HEART_ABNORMAL_LOW_BPM 50        // Low heart rate threshold

// === AMBIENT LIGHT SENSOR ===
#define LOW_LIGHT_THRESHOLD_LUX 100      // lux - brightness below which LED enables
#define LIGHT_SENSOR_UPDATE_INTERVAL 1000 // ms - update light sensor reading

// === LED ILLUMINATION (GPIO MODE) ===
#define LED_ILLUMINATION_PIN 13          // Nano A6 high-power LED PWM output
#define BOOST_ENABLE_PIN 14              // Nano A7 boost converter EN control
#define LED_BRIGHTNESS_LOW_LIGHT 150     // Default brightness in low-light
#define LED_BRIGHTNESS_OBSTACLE 200      // Brightness for obstacle warning
#define LED_BRIGHTNESS_EMERGENCY 255     // Full brightness during emergency

// === HAPTIC DRIVER (DRV2605L) ===
#define HAPTIC_PIN 255                   // Unused in current DRV2605L I2C configuration
#define HAPTIC_I2C_DRIVER true           // Use I2C driver vs GPIO PWM

// === EMERGENCY SYSTEM ===
#define EMERGENCY_DURATION_MS 30000      // 30 seconds max emergency alerts
#define EMERGENCY_INITIAL_INTENSITY_MS 3000  // 3 seconds of max intensity

// === POWER MODE SAMPLING RATES (ms intervals) ===
// NORMAL MODE: ~80 Hz IMU, 25 Hz ultrasonic, 30 Hz LiDAR, 10 Hz pulse
#define NORMAL_IMU_INTERVAL 12           // ~80 Hz (responsive motion + fall detection)
#define NORMAL_ULTRASONIC_INTERVAL 40    // 25 Hz  (frequent proximity checks)
#define NORMAL_MATRIX_SENSOR_INTERVAL 33 // 30 Hz  (rapid forward updates)
#define NORMAL_PULSE_INTERVAL 100        // 10 Hz  (real-time stress capability)
#define NORMAL_BATTERY_CHECK_INTERVAL 2000  // 2 seconds (increased frequency)

// LOW_POWER MODE: 5 Hz all sensors (battery <20% fallback)
#define LOW_POWER_IMU_INTERVAL 200       // 5 Hz   (fall detection only)
#define LOW_POWER_ULTRASONIC_INTERVAL 200 // 5 Hz  (coarse checks)
#define LOW_POWER_MATRIX_SENSOR_INTERVAL 200     // 5 Hz   (sparse awareness)
#define LOW_POWER_PULSE_INTERVAL 500     // 2 Hz   (minimal overhead)
#define LOW_POWER_BATTERY_CHECK_INTERVAL 10000  // 10 seconds

// HIGH_STRESS MODE: 50 Hz IMU, 30 Hz ultrasonic/LiDAR, 20 Hz pulse (close obstacle + abnormal HR)
#define HIGH_STRESS_IMU_INTERVAL 20      // 50 Hz  (rapid threat detection)
#define HIGH_STRESS_ULTRASONIC_INTERVAL 33 // 30 Hz (very frequent proximity)
#define HIGH_STRESS_MATRIX_SENSOR_INTERVAL 33    // 30 Hz  (rapid threat updates)
#define HIGH_STRESS_PULSE_INTERVAL 50    // 20 Hz  (stress level tracking)
#define HIGH_STRESS_BATTERY_CHECK_INTERVAL 1000 // 1 second

// EMERGENCY MODE: 100+ Hz IMU, 40 Hz ultrasonic/LiDAR, 40 Hz pulse (fall detection, time-limited)
#define EMERGENCY_IMU_INTERVAL 10        // 100 Hz (maximum fall impact resolution)
#define EMERGENCY_ULTRASONIC_INTERVAL 25 // 40 Hz  (ground impact + environment)
#define EMERGENCY_MATRIX_SENSOR_INTERVAL 25      // 40 Hz  (detailed landing mapping)
#define EMERGENCY_PULSE_INTERVAL 25      // 40 Hz  (stress spike capture)
#define EMERGENCY_BATTERY_CHECK_INTERVAL 500  // 0.5 second

// === RESPONSE SYSTEM TIMING ===
#define RESPONSE_PULSE_FAR_MS 300        // Slow pulse for distant obstacles
#define RESPONSE_PULSE_NEAR_MS 150       // Medium pulse for near obstacles
#define RESPONSE_PULSE_IMMINENT_MS 50    // Fast pulse for imminent obstacles
#define RESPONSE_PULSE_STRESS_MS 25      // Very fast pulse for high stress
#define RESPONSE_PULSE_FALL_MS 100       // Pulsed fall alert (not continuous)

// === LED BRIGHTNESS LEVELS ===
#define LED_OFF 0
#define LED_DIM 100
#define LED_MEDIUM 180
#define LED_BRIGHT 255

// === SENSOR ERROR VALUES ===
#define SENSOR_ERROR_DISTANCE 0xFFFF     // Invalid distance reading
#define SENSOR_ERROR_HEART -1            // Invalid heart rate
#define SENSOR_ERROR_IMU NAN             // Invalid IMU reading

// === FAULT DETECTION ===
#define SENSOR_FAIL_THRESHOLD 5          // Consecutive failures before fault
#define SENSOR_RECOVERY_TIME_MS 10000    // Backoff between recovery attempts

// BLE healthFlags bits: 1 = device/branch healthy and usable
#define HEALTH_IMU_OK 0x0001
#define HEALTH_ULTRASONIC_OK 0x0002
#define HEALTH_MATRIX_SENSOR_OK 0x0004
#define HEALTH_PULSE_OK 0x0008
#define HEALTH_MUX_OK 0x0010
#define HEALTH_HAPTIC_HEAD_OK 0x0020
#define HEALTH_HAPTIC_LEFT_OK 0x0040
#define HEALTH_HAPTIC_RIGHT_OK 0x0080

// === BLE CONFIGURATION ===
#define BLE_DEVICE_NAME "ProtoSmartCane"
#define BLE_SERVICE_UUID "10000001-1000-1000-1000-100000000000"
#define BLE_CHARACTERISTIC_UUID "10000004-1000-1000-1000-100000000000"
#define BLE_TELEMETRY_VERSION 0x03    // legacy constant; app-compatible packet has no version byte

// === BLE TELEMETRY OPTIMIZATION ===
// The cane sends minimal data; the app calculates battery lifetime using this power profile:
//   NORMAL: 85 mA → ~77 hours @ 6600mAh
//   LOW_POWER: 50 mA → ~118 hours @ 6600mAh
//   EMERGENCY: 250 mA → ~26 hours @ 6600mAh (capped 30s)
//   CAUTIOUS_SLEEP: 30 mA → ~198 hours @ 6600mAh
//   DEEP_SLEEP: 10 mA → ~594 hours @ 6600mAh
//
// App telemetry input (5 bytes):
//   [battery_percent] [current_mode] [heart_rate] [flags] [reserved]
// App output:
//   Estimated runtime = 4400mAh / current_power_in_mode × battery_percent / 100
//   Example: 85% battery in NORMAL mode → 85 / 100 × 47.6 hours = 40.46 hours remaining

// === SERIAL DEBUGGING ===
#define SERIAL_BAUD_RATE 115200
#define DEBUG_MODE true  // Set to false for production
#ifndef ENABLE_BLE
#define ENABLE_BLE true  // Enabled for software-only diagnostics and telemetry validation
#endif

#define DEBUG_WAIT_FOR_SERIAL_MS 3000
#define BOOT_LED_SELF_TEST false
#define BOOT_HAPTIC_SELF_TEST false
#define BOOT_MINIMAL_MODE false

// === ISOLATED SENSOR TEST MODE ===
// Keeps only IMU, ultrasonic, and 8x8 active for bring-up testing.
#define ISOLATED_SENSOR_TEST_MODE true
#define SENSOR_DEBUG_PRINT_INTERVAL_MS 250

// Three currently wired directional haptic outputs.
#define TEST_HAPTIC_HEAD_PIN HAPTIC_HEAD_PIN
#define TEST_HAPTIC_LEFT_PIN HAPTIC_LEFT_PIN
#define TEST_HAPTIC_RIGHT_PIN HAPTIC_RIGHT_PIN
