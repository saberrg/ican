#ifndef CAMERA_QUALITY_H
#define CAMERA_QUALITY_H

#include <stddef.h>
#include <stdint.h>

namespace ican_eye_quality {

enum CameraQualityFlag : uint8_t {
  QUALITY_OK = 0,
  QUALITY_DIM = 1 << 0,
  QUALITY_BRIGHT = 1 << 1,
  QUALITY_LOW_CONTRAST = 1 << 2,
  QUALITY_LARGE_JPEG = 1 << 3,
};

struct CameraQualitySnapshot {
  uint8_t brightnessEstimate;
  uint8_t contrastEstimate;
  uint8_t flags;
  const char *tuneAction;
};

CameraQualitySnapshot analyzeJpegQuality(const uint8_t *jpeg, size_t len,
                                         int profileIndex);

} // namespace ican_eye_quality

#endif // CAMERA_QUALITY_H
