/*
 * Haptic Driver Implementation (DRV2605L)
 * 3 independent DRV2605 drivers: 
 *   - Head haptic motor
 *   - Left haptic motor
 *   - Right haptic motor
 */

#include "haptic_driver.h"
#include <Wire.h>

// Module-level state variables
uint8_t hapticIntensity = 0;
unsigned long lastHapticPulse = 0;
uint16_t hapticPulseInterval = 0;

#define HAPTIC_DETECTION_LOGIC_MAX_MM 1500
#define HAPTIC_DETECTION_LOGIC_MIN_MM 400
#define HAPTIC_DETECTION_LOGIC_INVALID_MM 9999
#define HAPTIC_DETECTION_LOGIC_ON_INTENSITY HAPTIC_MEDIUM

// Track state for each haptic driver
struct HapticDriverState {
    bool initialized;
    uint8_t channel;
    unsigned long lastPulse;
    unsigned long pulseStopAt;
    uint16_t pulseInterval;
    uint8_t currentIntensity;
    bool active;
} hapticDrivers[3] = {
    {false, HAPTIC_HEAD_CHANNEL, 0, 0, 0, 0, false},
    {false, HAPTIC_LEFT_CHANNEL, 0, 0, 0, 0, false},
    {false, HAPTIC_RIGHT_CHANNEL, 0, 0, 0, 0, false}
};

static unsigned long headTimer = 0;
static unsigned long waistTimer = 0;
static bool headState = false;
static bool waistState = false;

enum WaistHapticTarget {
    WAIST_TARGET_NONE,
    WAIST_TARGET_FRONT,
    WAIST_TARGET_LEFT,
    WAIST_TARGET_RIGHT
};

static WaistHapticTarget waistTarget = WAIST_TARGET_NONE;

void hapticDriverInit() {
    // Diagnostic: I2C bus scan to find what devices are present
    if (DEBUG_MODE) {
        Serial.println("=== I2C BUS SCAN (Primary I2C: GPIO11/12) ===");
        Serial.println("Scanning addresses 0x00-0x7F:");
        
        for (uint8_t addr = 0; addr < 128; addr++) {
            Wire.beginTransmission(addr);
            uint8_t result = Wire.endTransmission();
            
            if (result == 0) {
                Serial.print("Device found at 0x");
                if (addr < 0x10) Serial.print("0");
                Serial.println(addr, HEX);
            }
        }
        Serial.println("=== End of scan ===");
    }
    
    // Full mux sweep: detect any DRV2605 on any channel (0-7)
    if (DEBUG_MODE) {
        Serial.println("=== MUX CHANNEL SWEEP FOR DRV2605 (0x5A) ===");
        for (uint8_t ch = 0; ch < 8; ch++) {
            selectMuxChannel(ch);
            Wire.beginTransmission(DRV2605_ADDR);
            uint8_t chResult = Wire.endTransmission();
            Serial.print("Channel ");
            Serial.print(ch);
            Serial.print(": ");
            if (chResult == 0) {
                Serial.println("DRV2605 detected");
            } else {
                Serial.print("no response (err ");
                Serial.print(chResult);
                Serial.println(")");
            }
        }
        Serial.println("=== End channel sweep ===");
    }

    // Initialize all 3 configured DRV2605 drivers
    uint8_t detectedDrivers = 0;
    for (int i = 0; i < 3; i++) {
        HapticDriverState &driver = hapticDrivers[i];
        
        // Select appropriate mux channel
        if (i == DRIVER_HEAD) {
            selectHapticHead();
        } else if (i == DRIVER_LEFT) {
            selectHapticLeft();
        } else if (i == DRIVER_RIGHT) {
            selectHapticRight();
        }
        
        // Debug: show which channel we're on and attempt to find device
        if (DEBUG_MODE) {
            Serial.print("Haptic init driver ");
            Serial.print(i);
            Serial.print(" (channel ");
            Serial.print(driver.channel);
            Serial.print("): ");
        }
        
        // Check if DRV2605 is present on this channel
        Wire.beginTransmission(DRV2605_ADDR);
        uint8_t result = Wire.endTransmission();
        
        if (result == 0) {
            // Initialize DRV2605L - Set to RTP (real-time playback) mode
            Wire.beginTransmission(DRV2605_ADDR);
            Wire.write(0x01);  // Mode register
            Wire.write(0x05);  // RTP mode
            Wire.endTransmission();
            
            driver.initialized = true;
            detectedDrivers++;

#if BOOT_HAPTIC_SELF_TEST
            // Optional physical confirmation for wiring bring-up.
            Wire.beginTransmission(DRV2605_ADDR);
            Wire.write(0x02);  // RTP input register
            Wire.write(HAPTIC_STRONG);
            Wire.endTransmission();
            delay(220);
            Wire.beginTransmission(DRV2605_ADDR);
            Wire.write(0x02);  // RTP input register
            Wire.write(0x00);  // stop
            Wire.endTransmission();
            delay(180);
#endif
            
            if (DEBUG_MODE) {
                Serial.println("initialized (DRV2605L)");
            }
        } else {
            if (DEBUG_MODE) {
                Serial.print("not found (I2C error code ");
                Serial.print(result);
                Serial.println(")");
            }
        }
    }

    // Optional physical confirmation code on center disk.
#if BOOT_HAPTIC_SELF_TEST
    // Format: preamble (2 long pulses), then 3 slots:
    // slot1=head driver, slot2=left driver, slot3=right driver
    // In each slot: long pulse = detected, short pulse = not detected
    for (uint8_t i = 0; i < 2; i++) {
        digitalWrite(HAPTIC_DISK_PIN, HIGH);
        delay(260);
        digitalWrite(HAPTIC_DISK_PIN, LOW);
        delay(180);
    }

    for (uint8_t i = 0; i < 3; i++) {
        bool ok = hapticDrivers[i].initialized;
        digitalWrite(HAPTIC_DISK_PIN, HIGH);
        delay(ok ? 260 : 80);
        digitalWrite(HAPTIC_DISK_PIN, LOW);
        delay(260);
    }

    // Additional count pulses for quick sanity check
    delay(220);
    for (uint8_t i = 0; i < detectedDrivers; i++) {
        digitalWrite(HAPTIC_DISK_PIN, HIGH);
        delay(100);
        digitalWrite(HAPTIC_DISK_PIN, LOW);
        delay(100);
    }
#endif
}

void hapticDriverUpdate() {
    unsigned long now = millis();
    for (uint8_t driverIndex = 0; driverIndex < 3; driverIndex++) {
        HapticDriverState &driver = hapticDrivers[driverIndex];
        if (driver.active && driver.pulseStopAt != 0 && now >= driver.pulseStopAt) {
            hapticStop(driverIndex);
        }
    }
}

void updateHapticFeedback() {
    hapticDriverUpdate();

    // Mirrors ReferencedLogic/detection_logic.ino LED behavior:
    // binary on/off toggles, one closest-obstacle interval, independent head,
    // and waist priority of front -> both, left -> left, right -> right.
    // EXCLUSION: FALL_DETECTED - no haptic feedback during fall (not useful for safety)
    if (currentSituation == FALL_DETECTED) {
        hapticStop(DRIVER_HEAD);
        hapticStop(DRIVER_LEFT);
        hapticStop(DRIVER_RIGHT);
        headState = false;
        waistState = false;
        return;
    }

    if (currentSituation == HIGH_STRESS_EVENT) {
        unsigned long now = millis();
        if (now - lastHapticPulse >= RESPONSE_PULSE_STRESS_MS) {
            bool on = !hapticDrivers[DRIVER_HEAD].active;
            hapticSet(DRIVER_HEAD, on ? HAPTIC_STRONG : HAPTIC_OFF);
            hapticSet(DRIVER_LEFT, on ? HAPTIC_STRONG : HAPTIC_OFF);
            hapticSet(DRIVER_RIGHT, on ? HAPTIC_STRONG : HAPTIC_OFF);
            lastHapticPulse = now;
        }
        return;
    }

    auto inFeedbackWindow = [](uint16_t distanceMm) {
        return distanceMm != SENSOR_ERROR_DISTANCE &&
               distanceMm <= HAPTIC_DETECTION_LOGIC_MAX_MM;
    };

    bool headDetected = currentSensors.matrixSensorHeadDetected &&
                        inFeedbackWindow(currentSensors.matrixSensorHeadDistance);
    bool waistFrontDetected = currentSensors.matrixSensorWaistDetected &&
                              inFeedbackWindow(currentSensors.matrixSensorWaistDistance);

    uint16_t headMm = currentSensors.matrixSensorHeadDetected ?
                      currentSensors.matrixSensorHeadDistance :
                      HAPTIC_DETECTION_LOGIC_INVALID_MM;
    (void)headMm;

    uint16_t frontMm = waistFrontDetected ?
                       currentSensors.matrixSensorWaistDistance :
                       HAPTIC_DETECTION_LOGIC_INVALID_MM;
    uint16_t leftMm = inFeedbackWindow(currentSensors.ultrasonicDistances[0]) ?
                      currentSensors.ultrasonicDistances[0] :
                      HAPTIC_DETECTION_LOGIC_INVALID_MM;
    uint16_t rightMm = inFeedbackWindow(currentSensors.ultrasonicDistances[1]) ?
                       currentSensors.ultrasonicDistances[1] :
                       HAPTIC_DETECTION_LOGIC_INVALID_MM;

    uint16_t closest = min(frontMm, min(leftMm, rightMm));
    WaistHapticTarget nextWaistTarget = WAIST_TARGET_NONE;
    if (closest < HAPTIC_DETECTION_LOGIC_INVALID_MM) {
        if (closest == frontMm) {
            nextWaistTarget = WAIST_TARGET_FRONT;
        } else if (closest == leftMm) {
            nextWaistTarget = WAIST_TARGET_LEFT;
        } else if (closest == rightMm) {
            nextWaistTarget = WAIST_TARGET_RIGHT;
        }
    }

    unsigned long interval = 500;
    if (closest < HAPTIC_DETECTION_LOGIC_INVALID_MM) {
        uint16_t constrainedDistance = max<uint16_t>(closest, HAPTIC_DETECTION_LOGIC_MIN_MM);
        interval = map(constrainedDistance,
                       HAPTIC_DETECTION_LOGIC_MIN_MM,
                       HAPTIC_DETECTION_LOGIC_MAX_MM,
                       50,
                       500);
    }

    unsigned long now = millis();

    if (nextWaistTarget != waistTarget) {
        waistTarget = nextWaistTarget;
        waistState = false;
        hapticStop(DRIVER_LEFT);
        hapticStop(DRIVER_RIGHT);
        if (waistTarget != WAIST_TARGET_NONE) {
            waistTimer = now - interval;
        }
    }

    if (headDetected) {
        if (now - headTimer >= interval) {
            headTimer = now;
            headState = !headState;
            hapticSet(DRIVER_HEAD, headState ? HAPTIC_DETECTION_LOGIC_ON_INTENSITY : HAPTIC_OFF);
        }
    } else {
        headState = false;
        hapticStop(DRIVER_HEAD);
    }

    if (waistTarget != WAIST_TARGET_NONE) {
        if (now - waistTimer >= interval) {
            waistTimer = now;
            waistState = !waistState;

            hapticStop(DRIVER_LEFT);
            hapticStop(DRIVER_RIGHT);

            if (waistTarget == WAIST_TARGET_FRONT) {
                hapticSet(DRIVER_LEFT, waistState ? HAPTIC_DETECTION_LOGIC_ON_INTENSITY : HAPTIC_OFF);
                hapticSet(DRIVER_RIGHT, waistState ? HAPTIC_DETECTION_LOGIC_ON_INTENSITY : HAPTIC_OFF);
            } else if (waistTarget == WAIST_TARGET_LEFT) {
                hapticSet(DRIVER_LEFT, waistState ? HAPTIC_DETECTION_LOGIC_ON_INTENSITY : HAPTIC_OFF);
            } else if (waistTarget == WAIST_TARGET_RIGHT) {
                hapticSet(DRIVER_RIGHT, waistState ? HAPTIC_DETECTION_LOGIC_ON_INTENSITY : HAPTIC_OFF);
            }
        }
    } else {
        waistState = false;
        waistTarget = WAIST_TARGET_NONE;
        hapticStop(DRIVER_LEFT);
        hapticStop(DRIVER_RIGHT);
    }
}

void hapticSet(uint8_t driverIndex, uint8_t intensity) {
    if (driverIndex >= 3 || intensity == HAPTIC_OFF) {
        hapticStop(driverIndex);
        return;
    }

    HapticDriverState &driver = hapticDrivers[driverIndex];
    if (!driver.initialized) return;
    if (driver.active && driver.currentIntensity == intensity && driver.pulseStopAt == 0) return;

    if (driverIndex == DRIVER_HEAD) {
        selectHapticHead();
    } else if (driverIndex == DRIVER_LEFT) {
        selectHapticLeft();
    } else if (driverIndex == DRIVER_RIGHT) {
        selectHapticRight();
    }

    Wire.beginTransmission(DRV2605_ADDR);
    Wire.write(0x02);
    Wire.write(intensity);
    Wire.endTransmission();

    driver.active = true;
    driver.currentIntensity = intensity;
    driver.pulseStopAt = 0;

    if (DEBUG_MODE) {
        Serial.print("Haptic driver ");
        Serial.print(driverIndex);
        Serial.print(" state: ");
        Serial.println(intensity > 0 ? "ON" : "OFF");
    }
}

void hapticPulse(uint8_t driverIndex, uint8_t intensity, uint16_t durationMs) {
    // Send haptic pulse via DRV2605L RTP mode
    // Intensity: 0-255 (0 = off, 255 = maximum)

    if (driverIndex >= 3 || intensity == 0) {
        hapticStop(driverIndex);
        return;
    }

    HapticDriverState &driver = hapticDrivers[driverIndex];
    if (!driver.initialized) return;

    unsigned long now = millis();
    if (driver.active && driver.currentIntensity == intensity && now < driver.pulseStopAt) {
        return;
    }

    // Select correct mux channel
    if (driverIndex == DRIVER_HEAD) {
        selectHapticHead();
    } else if (driverIndex == DRIVER_LEFT) {
        selectHapticLeft();
    } else if (driverIndex == DRIVER_RIGHT) {
        selectHapticRight();
    }

    // Write to DRV2605L RTP data register
    Wire.beginTransmission(DRV2605_ADDR);
    Wire.write(0x02);           // RTP input register
    Wire.write(intensity);      // RTP data (0-255)
    Wire.endTransmission();

    driver.active = true;
    driver.currentIntensity = intensity;
    driver.pulseStopAt = now + durationMs;

    if (DEBUG_MODE && intensity > 0) {
        Serial.print("Haptic driver ");
        Serial.print(driverIndex);
        Serial.print(" pulse: ");
        Serial.print(intensity);
        Serial.print(" intensity, ");
        Serial.print(durationMs);
        Serial.println("ms");
    }
}

void hapticStop(uint8_t driverIndex) {
    if (driverIndex >= 3) return;

    HapticDriverState &driver = hapticDrivers[driverIndex];
    if (!driver.active || !driver.initialized) return;

    // Select correct mux channel
    if (driverIndex == DRIVER_HEAD) {
        selectHapticHead();
    } else if (driverIndex == DRIVER_LEFT) {
        selectHapticLeft();
    } else if (driverIndex == DRIVER_RIGHT) {
        selectHapticRight();
    }

    // Stop haptic vibration
    Wire.beginTransmission(DRV2605_ADDR);
    Wire.write(0x02);  // RTP input register
    Wire.write(0x00);  // Stop vibration
    Wire.endTransmission();

    driver.active = false;
    driver.currentIntensity = 0;
    driver.pulseStopAt = 0;
}

uint8_t hapticDriverStatusBits() {
    uint8_t bits = 0;
    if (hapticDrivers[DRIVER_HEAD].initialized) {
        bits |= 0x10;
    }
    if (hapticDrivers[DRIVER_LEFT].initialized) {
        bits |= 0x20;
    }
    if (hapticDrivers[DRIVER_RIGHT].initialized) {
        bits |= 0x40;
    }
    return bits;
}

uint16_t hapticDriverHealthFlags() {
    uint16_t flags = 0;
    if (hapticDrivers[DRIVER_HEAD].initialized) {
        flags |= HEALTH_HAPTIC_HEAD_OK;
    }
    if (hapticDrivers[DRIVER_LEFT].initialized) {
        flags |= HEALTH_HAPTIC_LEFT_OK;
    }
    if (hapticDrivers[DRIVER_RIGHT].initialized) {
        flags |= HEALTH_HAPTIC_RIGHT_OK;
    }
    return flags;
}
