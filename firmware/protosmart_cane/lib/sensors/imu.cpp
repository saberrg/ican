/*
 * IMU Sensor (LSM6DSOX) Implementation
 * Handles fall detection and orientation sensing
 */

#include "imu.h"
#include <Wire.h>
#include <Adafruit_LSM6DSOX.h>
#include <math.h>

// IMU instance
static Adafruit_LSM6DSOX* lsm6dsox = nullptr;

// Fall detection state variables
enum FallState {
    FALL_STATE_NORMAL,
    FALL_STATE_FREE_FALL_DETECTED
};

static FallState fallState = FALL_STATE_NORMAL;
static unsigned long freeFallStartTime = 0;
static unsigned long lastFallTime = 0;
static unsigned long fallFlagSetTime = 0;
static unsigned long lastMotionTime = 0;

void imuInit() {
    // IMU is wired to the secondary I2C bus on D6/D7
    if (!lsm6dsox) lsm6dsox = new Adafruit_LSM6DSOX();
    if (!lsm6dsox->begin_I2C(IMU_I2C_ADDR, &Wire1)) {
        if (DEBUG_MODE) Serial.println("IMU initialization failed!");
        systemFaults.imu_fail = true;
        return;
    }

    if (DEBUG_MODE) Serial.println("IMU initialized successfully");
    systemFaults.imu_fail = false;
}

void imuUpdate() {
    sensors_event_t accel, gyro, temp;
    if (!lsm6dsox || !lsm6dsox->getEvent(&accel, &gyro, &temp)) {
        // Sensor read failed
        systemFaults.imu_fail = true;
        return;
    }

    // Update sensor data
    currentSensors.imu.ax = accel.acceleration.x;
    currentSensors.imu.ay = accel.acceleration.y;
    currentSensors.imu.az = accel.acceleration.z;
    currentSensors.imu.gx = gyro.gyro.x;
    currentSensors.imu.gy = gyro.gyro.y;
    currentSensors.imu.gz = gyro.gyro.z;

    // Match the reference fall sketch: acceleration magnitude in g, gyro in deg/s.
    float accelMagG = sqrt(
        currentSensors.imu.ax * currentSensors.imu.ax +
        currentSensors.imu.ay * currentSensors.imu.ay +
        currentSensors.imu.az * currentSensors.imu.az
    ) / 9.81f;

    float gyroMagDps = sqrt(
        currentSensors.imu.gx * currentSensors.imu.gx +
        currentSensors.imu.gy * currentSensors.imu.gy +
        currentSensors.imu.gz * currentSensors.imu.gz
    ) * 57.2958f;

    // === FALL DETECTION LOGIC ===
    unsigned long now = millis();

    switch (fallState) {
        case FALL_STATE_NORMAL:
            if (accelMagG < FALL_FREEFALL_THRESHOLD_G &&
                now - lastFallTime > FALL_COOLDOWN) {
                fallState = FALL_STATE_FREE_FALL_DETECTED;
                freeFallStartTime = now;

                if (DEBUG_MODE) Serial.println("Free fall detected...");
            }
            break;

        case FALL_STATE_FREE_FALL_DETECTED:
            if (now - freeFallStartTime <= FALL_IMPACT_WINDOW) {
                if (accelMagG > FALL_IMPACT_THRESHOLD_G &&
                    gyroMagDps > FALL_GYRO_THRESHOLD_DPS) {
                    Serial.println("========== FALL DETECTED ==========");
                    Serial.print("Impact Accel: ");
                    Serial.print(accelMagG);
                    Serial.print(" g | Gyro: ");
                    Serial.print(gyroMagDps);
                    Serial.println(" deg/s");
                    Serial.println("fallDetectedGlobal = TRUE");

                    currentSituation = FALL_DETECTED;
                    currentEmergencyType = EMERGENCY_FALL;
                    lastFallTime = now;
                    fallFlagSetTime = now;
                    fallState = FALL_STATE_NORMAL;
                }
            } else {
                fallState = FALL_STATE_NORMAL;
            }
            break;
        }

    if (currentSituation == FALL_DETECTED &&
        fallFlagSetTime != 0 &&
        now - fallFlagSetTime >= FALL_FLAG_HOLD_MS) {
        currentSituation = NONE;
        currentEmergencyType = EMERGENCY_NONE;
        fallFlagSetTime = 0;
        if (DEBUG_MODE) Serial.println("fallDetectedGlobal = FALSE");
    }

    // Track motion for inactivity detection
    if (accelMagG > 1.0f) {  // Some motion detected
        lastMotionTime = now;
    }

    // Mark sensor as working
    systemFaults.imu_fail = false;
}
