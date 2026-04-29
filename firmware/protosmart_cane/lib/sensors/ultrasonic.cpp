/*
 * Ultrasonic Sensor Implementation
 * Handles distance measurement using GPIO trigger/echo pins
 */

#include "ultrasonic.h"
#include <Arduino.h>

static uint16_t triggerUltrasonic(uint8_t trigPin, uint8_t echoPin) {
    digitalWrite(trigPin, LOW);
    delayMicroseconds(5);
    digitalWrite(trigPin, HIGH);
    delayMicroseconds(10);

    unsigned long duration = pulseIn(echoPin, LOW, 50000);
    if (duration == 0 || duration >= 50000) {
        return SENSOR_ERROR_DISTANCE;
    }

    float distanceMm = (duration / 50.0f) * 10.0f;
    if (distanceMm <= 0.0f || distanceMm > ULTRASONIC_MAX_RANGE_MM) {
        return SENSOR_ERROR_DISTANCE;
    }

    return static_cast<uint16_t>(distanceMm);
}

void ultrasonicInit() {
    pinMode(ULTRASONIC_LEFT_TRIG_PIN, OUTPUT);
    pinMode(ULTRASONIC_LEFT_ECHO_PIN, INPUT);
    pinMode(ULTRASONIC_RIGHT_TRIG_PIN, OUTPUT);
    pinMode(ULTRASONIC_RIGHT_ECHO_PIN, INPUT);

    digitalWrite(ULTRASONIC_LEFT_TRIG_PIN, HIGH);
    digitalWrite(ULTRASONIC_RIGHT_TRIG_PIN, HIGH);
    delay(50);

    systemFaults.ultrasonic_fail = false;
}

void ultrasonicUpdate() {
    // Read all ultrasonic sensors
    for (uint8_t i = 0; i < NUM_ULTRASONIC_SENSORS; i++) {
        currentSensors.ultrasonicDistances[i] = readUltrasonicDistance(i);

        // Update zone detection
        if (currentSensors.ultrasonicDistances[i] != SENSOR_ERROR_DISTANCE) {
            if (currentSensors.ultrasonicDistances[i] <= OBSTACLE_IMMINENT_MM) {
                currentSensors.ultrasonicZones[i] = OBSTACLE_IMMINENT;
            } else if (currentSensors.ultrasonicDistances[i] <= OBSTACLE_NEAR_MM) {
                currentSensors.ultrasonicZones[i] = OBSTACLE_NEAR;
            } else if (currentSensors.ultrasonicDistances[i] <= OBSTACLE_FAR_MM) {
                currentSensors.ultrasonicZones[i] = OBSTACLE_FAR;
            } else {
                currentSensors.ultrasonicZones[i] = OBSTACLE_NONE;
            }
        } else {
            currentSensors.ultrasonicZones[i] = OBSTACLE_NONE;
        }
    }

    // No echo usually means no object in range, not a hardware fault.
    systemFaults.ultrasonic_fail = false;
}

uint16_t readUltrasonicDistance(uint8_t sensorIndex) {
    if (sensorIndex >= NUM_ULTRASONIC_SENSORS) return SENSOR_ERROR_DISTANCE;

    uint8_t trigPin = (sensorIndex == 0) ? ULTRASONIC_LEFT_TRIG_PIN : ULTRASONIC_RIGHT_TRIG_PIN;
    uint8_t echoPin = (sensorIndex == 0) ? ULTRASONIC_LEFT_ECHO_PIN : ULTRASONIC_RIGHT_ECHO_PIN;
    return triggerUltrasonic(trigPin, echoPin);
}
