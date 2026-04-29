/**
 * camera.cpp — Camera Module Implementation
 *
 * Handles camera init, sensor tuning, profile switching, and frame capture
 * on the XIAO ESP32-S3 Sense.
 */

#include "camera.h"
#include <Arduino.h>

// Camera pin definitions (resolved relative to project root)
#define CAMERA_MODEL_XIAO_ESP32S3
#include "../../include/camera_pins.h"

// =========================================================================
// Profile Table
// =========================================================================

const CameraProfile profiles[] = {
    {"FAST",     FRAMESIZE_VGA,   12}, // 0: 640x480   ~8-15 KB
    {"BALANCED", FRAMESIZE_SVGA,  10}, // 1: 800x600   ~20-40 KB
    {"QUALITY",  FRAMESIZE_XGA,    8}, // 2: 1024x768  ~40-70 KB
    {"MAX",      FRAMESIZE_UXGA,   8}, // 3: 1600x1200 ~80-150 KB
};
const int NUM_PROFILES = sizeof(profiles) / sizeof(profiles[0]);

// Default to FAST for reliability: VGA + quality 12 keeps JPEGs in the
// ~8-15 KB range so a single capture finishes over BLE well before the
// iOS ACL queue saturates. Operators can still switch via the PROFILE
// command for diagnostics.
static int currentProfile = 0; // default: FAST

// =========================================================================
// Init
// =========================================================================

void initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;

  // Start at current profile resolution
  config.frame_size   = profiles[currentProfile].frameSize;
  config.jpeg_quality = profiles[currentProfile].jpegQuality;

  // Use 2 frame buffers with PSRAM for faster capture cycle
  if (psramFound()) {
    config.fb_count  = 2;
    config.grab_mode = CAMERA_GRAB_LATEST;
    config.fb_location = CAMERA_FB_IN_PSRAM;
    Serial.printf("[CAM] PSRAM found: %d bytes free — using 2 frame buffers\n",
                  ESP.getFreePsram());
  } else {
    config.fb_count  = 1;
    config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
    Serial.println("[CAM] No PSRAM — single frame buffer");
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[CAM] Init failed: 0x%x\n", err);
    return;
  }

  // Sensor tuning: sharp, balanced exposure for readable text and hazards.
  sensor_t *s = esp_camera_sensor_get();
  if (s) {
    s->set_brightness(s, 1);             // +1 (was +2, too washed out)
    s->set_contrast(s, 1);              // +1 for text readability
    s->set_saturation(s, 0);            // neutral
    s->set_sharpness(s, 2);             // +2 sharpness for text/edges
    s->set_denoise(s, 1);              // light denoise (reduce grain)
    s->set_whitebal(s, 1);             // auto white balance ON
    s->set_awb_gain(s, 1);             // AWB gain ON
    s->set_wb_mode(s, 0);              // auto WB mode
    s->set_aec2(s, 1);                 // advanced AEC ON
    s->set_ae_level(s, 1);             // +1 (was +2, overexposed)
    s->set_gainceiling(s, GAINCEILING_8X); // 8x (was 16x, less noise)
  }

  Serial.printf("[CAM] Initialized — profile: %s\n",
                profiles[currentProfile].name);

  // Warm-up: 6 frames with 300ms gap so auto-exposure settles
  for (int i = 0; i < 6; i++) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb)
      esp_camera_fb_return(fb);
    delay(300);
  }
  Serial.println("[CAM] Warm-up complete");
}

// =========================================================================
// Profile Switching
// =========================================================================

void applyProfile(int idx) {
  if (idx < 0 || idx >= NUM_PROFILES)
    return;
  currentProfile = idx;

  sensor_t *s = esp_camera_sensor_get();
  if (s) {
    s->set_framesize(s, profiles[idx].frameSize);
    s->set_quality(s, profiles[idx].jpegQuality);
    Serial.printf("[CAM] Profile set: %s (quality=%d)\n", profiles[idx].name,
                  profiles[idx].jpegQuality);
  }

  // Take a throwaway frame so the new settings take effect
  camera_fb_t *fb = esp_camera_fb_get();
  if (fb)
    esp_camera_fb_return(fb);
  delay(100);
}

int getCurrentProfile() { return currentProfile; }

// =========================================================================
// Capture
// =========================================================================

camera_fb_t *capturePhoto() {
  // Discard stale frame, keep fresh one
  camera_fb_t *stale = esp_camera_fb_get();
  if (stale)
    esp_camera_fb_return(stale);
  delay(50);

  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("[CAM] Capture failed");
    return nullptr;
  }

  Serial.printf("[CAM] Photo captured: %u bytes (%s)\n", fb->len,
                profiles[currentProfile].name);
  return fb;
}
