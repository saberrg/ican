/*
 * Sensor Fusion Module
 * Combines data from all sensors to determine current situation
 */

#include "fusion.h"

void fuseSituations() {
    // Fall detection is set by the IMU path and has higher priority than
    // obstacle fusion, including in isolated sensor test mode.
    if (currentSituation == FALL_DETECTED) {
        return;
    }

    // Get minimum distance from all sensors
    uint16_t minDistance = 0xFFFF;  // Start with max value

    // Check ultrasonic sensors
    for (uint8_t i = 0; i < NUM_ULTRASONIC_SENSORS; i++) {
        if (currentSensors.ultrasonicDistances[i] != SENSOR_ERROR_DISTANCE &&
            currentSensors.ultrasonicDistances[i] < minDistance) {
            minDistance = currentSensors.ultrasonicDistances[i];
        }
    }

    // Check matrix sensor
    if (currentSensors.matrixSensorDistance != SENSOR_ERROR_DISTANCE &&
        currentSensors.matrixSensorDistance < minDistance) {
        minDistance = currentSensors.matrixSensorDistance;
    }

    // PRIORITY 1: FALL DETECTION (highest priority - triggers emergency)
    // This is handled by the IMU update function directly

    // PRIORITY 2: HIGH STRESS CONDITION
    // Close obstacle + abnormal heart rate
    if (minDistance <= OBSTACLE_IMMINENT_MM && currentSensors.heartAbnormal) {
        currentSituation = HIGH_STRESS_EVENT;
        return;
    }

    // PRIORITY 3: OBSTACLE DETECTION HIERARCHY
    if (minDistance <= OBSTACLE_IMMINENT_MM) {
        currentSituation = OBJECT_IMMINENT;
    } else if (minDistance <= OBSTACLE_NEAR_MM) {
        currentSituation = OBJECT_NEAR;
    } else if (minDistance <= OBSTACLE_FAR_MM) {
        currentSituation = OBJECT_FAR;
    } else {
        currentSituation = NONE;
    }
}
