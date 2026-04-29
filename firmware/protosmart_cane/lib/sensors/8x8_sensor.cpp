/*
 * 8x8 Matrix Sensor Implementation
 * Handles forward obstacle detection using DFRobot 8x8 matrix sensor.
 *
 * Features:
 * - Hysteresis thresholds to prevent zone flickering
 * - Exponential moving average smoothing for distance jitter reduction
 * - Zone persistence tracking (N-frame confirmation before state change)
 */

#include "8x8_sensor.h"
#include <Wire.h>
#include <DFRobot_matrixLidarDistanceSensor.h>

// Use Wire1 directly — avoids static TwoWire(1) construction crashing before setup()
static DFRobot_matrixLidarDistanceSensor* tof = nullptr;
static uint16_t matrixSensorBuffer[64];

// === HYSTERESIS THRESHOLDS (prevent zone flickering) ===
// When entering IMMINENT, use lower threshold; when leaving, use higher
#define IMMINENT_ENTER_MM 180     // Enter IMMINENT zone
#define IMMINENT_EXIT_MM 220      // Exit IMMINENT zone (hysteresis = 40mm)

#define NEAR_ENTER_MM 450         // Enter NEAR zone
#define NEAR_EXIT_MM 550          // Exit NEAR zone (hysteresis = 100mm)

#define FAR_ENTER_MM 950          // Enter FAR zone
#define FAR_EXIT_MM 1050          // Exit FAR zone (hysteresis = 100mm)

// === DISTANCE SMOOTHING (exponential moving average) ===
#define MATRIX_SENSOR_SMOOTH_FACTOR 0.7f  // 0.0-1.0: higher = more aggressive smoothing

// === ZONE PERSISTENCE (require N consecutive frames) ===
#define ZONE_CONFIRMATION_FRAMES 2  // Require 2 consecutive frames to confirm zone change

// Static state tracking
static uint16_t smoothedHeadDistance = SENSOR_ERROR_DISTANCE;
static uint16_t smoothedWaistDistance = SENSOR_ERROR_DISTANCE;
static uint16_t smoothedOverallDistance = SENSOR_ERROR_DISTANCE;
static ObstacleZone previousZone = OBSTACLE_NONE;
static uint8_t zoneConfirmationCounter = 0;

static ObstacleZone computeZoneWithHysteresis(uint16_t distance) {
    // Apply hysteresis: use different thresholds depending on current zone
    if (previousZone == OBSTACLE_IMMINENT) {
        if (distance > IMMINENT_EXIT_MM) {
            return OBSTACLE_NEAR;
        }
        return OBSTACLE_IMMINENT;
    } else if (previousZone == OBSTACLE_NEAR) {
        if (distance <= IMMINENT_ENTER_MM) {
            return OBSTACLE_IMMINENT;
        } else if (distance > NEAR_EXIT_MM) {
            return OBSTACLE_FAR;
        }
        return OBSTACLE_NEAR;
    } else if (previousZone == OBSTACLE_FAR) {
        if (distance <= NEAR_ENTER_MM) {
            return OBSTACLE_NEAR;
        } else if (distance > FAR_EXIT_MM) {
            return OBSTACLE_NONE;
        }
        return OBSTACLE_FAR;
    } else {
        // From NONE, use entry thresholds
        if (distance <= IMMINENT_ENTER_MM) {
            return OBSTACLE_IMMINENT;
        } else if (distance <= NEAR_ENTER_MM) {
            return OBSTACLE_NEAR;
        } else if (distance <= FAR_ENTER_MM) {
            return OBSTACLE_FAR;
        }
        return OBSTACLE_NONE;
    }
}

static uint16_t smoothDistance(uint16_t rawDistance, uint16_t previousSmoothed) {
    if (rawDistance == SENSOR_ERROR_DISTANCE) {
        return SENSOR_ERROR_DISTANCE;
    }

    if (previousSmoothed == SENSOR_ERROR_DISTANCE) {
        return rawDistance;  // First reading, no smoothing
    }

    // Exponential moving average: smooth = (raw * factor) + (prev * (1 - factor))
    uint16_t smoothed = (uint16_t)(rawDistance * MATRIX_SENSOR_SMOOTH_FACTOR +
                                   previousSmoothed * (1.0f - MATRIX_SENSOR_SMOOTH_FACTOR));
    return smoothed;
}

void matrixSensorInit() {
    // Wire1 already begun in muxInit() before sensorsInit() is called
    delay(100);

    if (!tof) {
        tof = new DFRobot_matrixLidarDistanceSensor(MATRIX_SENSOR_I2C_ADDR, &Wire1);
    }

    uint8_t beginAttempts = 0;
    while (tof->begin() != 0 && beginAttempts < 5) {
        beginAttempts++;
        if (DEBUG_MODE) Serial.println("8x8 Matrix Sensor begin retry");
        delay(MATRIX_SENSOR_INIT_RETRY_DELAY_MS);
    }

    if (beginAttempts >= 5) {
        if (DEBUG_MODE) Serial.println("8x8 Matrix Sensor initialization failed!");
        systemFaults.matrixSensor_fail = true;
        return;
    }

    uint8_t configAttempts = 0;
    while (tof->getAllDataConfig(eMatrix_8X8) != 0 && configAttempts < 5) {
        configAttempts++;
        if (DEBUG_MODE) Serial.println("8x8 Matrix Sensor config retry");
        delay(MATRIX_SENSOR_INIT_RETRY_DELAY_MS);
    }

    if (configAttempts >= 5) {
        if (DEBUG_MODE) Serial.println("8x8 Matrix Sensor matrix configuration failed!");
        systemFaults.matrixSensor_fail = true;
        return;
    }

    if (DEBUG_MODE) Serial.println("8x8 Matrix Sensor initialized successfully");
    systemFaults.matrixSensor_fail = false;
}

void matrixSensorUpdate() {
    bool headDetected = false;
    bool waistDetected = false;
    uint16_t closestHead = SENSOR_ERROR_DISTANCE;
    uint16_t closestWaist = SENSOR_ERROR_DISTANCE;
    uint16_t closestOverall = SENSOR_ERROR_DISTANCE;

    if (!tof || tof->getAllData(matrixSensorBuffer) != 0) {
        if (DEBUG_MODE) Serial.println("8x8 Matrix Sensor data read failed");
        currentSensors.matrixSensorDistance = SENSOR_ERROR_DISTANCE;
        currentSensors.matrixSensorHeadDetected = false;
        currentSensors.matrixSensorWaistDetected = false;
        currentSensors.matrixSensorHeadDistance = SENSOR_ERROR_DISTANCE;
        currentSensors.matrixSensorWaistDistance = SENSOR_ERROR_DISTANCE;
        currentSensors.matrixSensorZone = OBSTACLE_NONE;
        systemFaults.matrixSensor_fail = true;
        return;
    }

    for (uint8_t i = 0; i < 64; i++) {
        uint16_t distance = matrixSensorBuffer[i];
        if (distance == 0 || distance > MATRIX_SENSOR_MAX_DISTANCE_MM) continue;

        if (closestOverall == SENSOR_ERROR_DISTANCE || distance < closestOverall) {
            closestOverall = distance;
        }

        uint8_t row = i / 8;
        uint8_t col = i % 8;

        if (row < 4) {
            headDetected = true;
            if (closestHead == SENSOR_ERROR_DISTANCE || distance < closestHead) {
                closestHead = distance;
            }
        }

        if (row >= 4 && col >= 1 && col <= 6) {
            waistDetected = true;
            if (closestWaist == SENSOR_ERROR_DISTANCE || distance < closestWaist) {
                closestWaist = distance;
            }
        }
    }

    currentSensors.matrixSensorHeadDetected = headDetected;
    currentSensors.matrixSensorWaistDetected = waistDetected;
    currentSensors.matrixSensorHeadDistance = headDetected ? closestHead : SENSOR_ERROR_DISTANCE;
    currentSensors.matrixSensorWaistDistance = waistDetected ? closestWaist : SENSOR_ERROR_DISTANCE;
    currentSensors.matrixSensorDistance = (closestOverall == SENSOR_ERROR_DISTANCE) ?
                                  SENSOR_ERROR_DISTANCE : closestOverall;

    // === DISTANCE SMOOTHING ===
    smoothedHeadDistance = smoothDistance(currentSensors.matrixSensorHeadDistance, smoothedHeadDistance);
    smoothedWaistDistance = smoothDistance(currentSensors.matrixSensorWaistDistance, smoothedWaistDistance);
    smoothedOverallDistance = smoothDistance(currentSensors.matrixSensorDistance, smoothedOverallDistance);

    // === ZONE DETECTION WITH HYSTERESIS & PERSISTENCE ===
    if (currentSensors.matrixSensorDistance != SENSOR_ERROR_DISTANCE) {
        ObstacleZone rawZone = computeZoneWithHysteresis(smoothedOverallDistance);

        // Require N consecutive frames in the new zone before confirming zone change
        if (rawZone != previousZone) {
            zoneConfirmationCounter++;
            if (zoneConfirmationCounter >= ZONE_CONFIRMATION_FRAMES) {
                previousZone = rawZone;
                currentSensors.matrixSensorZone = rawZone;
                zoneConfirmationCounter = 0;
                if (DEBUG_MODE) {
                    Serial.print("Zone changed to: ");
                    Serial.println((int)rawZone);
                }
            }
        } else {
            zoneConfirmationCounter = 0;
            currentSensors.matrixSensorZone = previousZone;
        }

        systemFaults.matrixSensor_fail = false;
    } else {
        currentSensors.matrixSensorZone = OBSTACLE_NONE;
        previousZone = OBSTACLE_NONE;
        zoneConfirmationCounter = 0;
        systemFaults.matrixSensor_fail = false;
    }
}

// === ACCESSOR FUNCTIONS for advanced handling ===

uint16_t matrixSensorGetSmoothedDistance() {
    return smoothedOverallDistance;
}
