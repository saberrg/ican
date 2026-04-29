/**
 * camera.h — Camera Module Interface
 *
 * Wraps the XIAO ESP32-S3 Sense camera behind a clean
 * init / capture / profile API.  Callers never touch esp_camera directly.
 */

#ifndef CAMERA_H
#define CAMERA_H

#include "esp_camera.h"
#include <stdint.h>

// =========================================================================
// Quality Profiles
// =========================================================================

struct CameraProfile {
  const char *name;
  framesize_t frameSize;
  int jpegQuality; // 0-63, lower = better quality, bigger file
};

/** Number of available profiles. */
extern const int NUM_PROFILES;

/** Profile table — indexed by profile number. */
extern const CameraProfile profiles[];

// =========================================================================
// Public API
// =========================================================================

/**
 * Initialize the camera hardware and apply the firmware-safe default profile
 * (FAST). The app may request BALANCED for clean manual Describe captures.
 * Must be called once in setup().
 */
void initCamera();

/**
 * Switch to a different quality profile on the fly.
 * @param idx  Profile index (0 = FAST … 3 = MAX).
 */
void applyProfile(int idx);

/**
 * Get the currently active profile index.
 */
int getCurrentProfile();

/**
 * Return the detected camera sensor name for STATUS diagnostics.
 */
const char *getCameraSensorName();

/**
 * Last lightweight quality metrics captured from the JPEG stream.
 * Values are best-effort compressed-frame estimates for diagnostics and
 * next-capture tuning, not calibrated optical measurements.
 */
uint8_t getCameraQualityBrightnessEstimate();
uint8_t getCameraQualityContrastEstimate();
uint8_t getCameraQualityFlags();
const char *getCameraQualityTuneAction();

/**
 * Capture a fresh JPEG frame.  Discards a stale frame internally.
 * Caller MUST call esp_camera_fb_return(fb) when done.
 * Returns nullptr on failure.
 */
camera_fb_t *capturePhoto();

#endif // CAMERA_H
