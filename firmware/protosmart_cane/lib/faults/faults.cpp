/*
 * Fault Detection and Recovery System
 * Monitors sensor health and implements recovery strategies
 */

#include "faults.h"
#include "../sensors/imu.h"
#include "../sensors/ultrasonic.h"
#include "../sensors/8x8_sensor.h"
#include "../sensors/pulse.h"
#include "../mux/mux.h"

void checkFaults() {
    // IMU fault detection - check for valid readings
    static uint8_t imuFailCount = 0;
    if (isnan(currentSensors.imu.ax) || isnan(currentSensors.imu.ay) || isnan(currentSensors.imu.az)) {
        imuFailCount++;
    } else {
        imuFailCount = 0;
    }
    if (imuFailCount >= SENSOR_FAIL_THRESHOLD) {
        systemFaults.imu_fail = true;
    }

    // Ranging sensors report SENSOR_ERROR_DISTANCE when no obstacle is in range.
    // Treat only module-level read/init failures as recoverable sensor faults.

    // Heart sensor auto-recovery disabled for now.
    // During normal use the pulse signal can legitimately be absent/noisy,
    // which would otherwise cause continuous fault-recovery loops.
    systemFaults.heart_fail = false;

    // Attempt recovery for failed sensors
    if ((systemFaults.imu_fail || systemFaults.ultrasonic_fail ||
         systemFaults.matrixSensor_fail || systemFaults.heart_fail ||
         systemFaults.mux_fail) &&
        (millis() - systemFaults.lastRecoveryAttempt > SENSOR_RECOVERY_TIME_MS)) {

        if (DEBUG_MODE) Serial.println("Attempting sensor recovery...");

        // Reinitialize failed sensors
        if (systemFaults.imu_fail) imuInit();
        if (systemFaults.ultrasonic_fail) ultrasonicInit();
        if (systemFaults.matrixSensor_fail) matrixSensorInit();
        if (systemFaults.heart_fail) pulseInit();
        if (systemFaults.mux_fail) muxInit();

        systemFaults.lastRecoveryAttempt = millis();
    }
}
