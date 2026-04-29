#include "camera_quality.h"

namespace ican_eye_quality {

namespace {

uint8_t clampByte(unsigned int value) {
  return value > 255u ? 255u : static_cast<uint8_t>(value);
}

size_t sampleStep(size_t len) {
  if (len <= 256u) return 1u;
  return len / 256u;
}

size_t largeJpegThreshold(int profileIndex) {
  switch (profileIndex) {
  case 0:
    return 24000u;
  case 1:
    return 52000u;
  case 2:
    return 90000u;
  default:
    return 150000u;
  }
}

} // namespace

CameraQualitySnapshot analyzeJpegQuality(const uint8_t *jpeg, size_t len,
                                         int profileIndex) {
  if (jpeg == nullptr || len == 0u) {
    return CameraQualitySnapshot{0, 0, QUALITY_DIM | QUALITY_LOW_CONTRAST,
                                 "boost_light"};
  }

  const size_t step = sampleStep(len);
  unsigned long sum = 0;
  unsigned int minValue = 255;
  unsigned int maxValue = 0;
  unsigned int samples = 0;

  // This intentionally samples the compressed JPEG byte stream. It is a cheap
  // proxy for "this frame likely needs help" rather than true pixel luminance.
  for (size_t i = 0; i < len; i += step) {
    const unsigned int value = jpeg[i];
    sum += value;
    if (value < minValue) minValue = value;
    if (value > maxValue) maxValue = value;
    samples++;
  }

  const uint8_t brightness =
      samples == 0 ? 0 : clampByte(static_cast<unsigned int>(sum / samples));
  const uint8_t contrast = clampByte(maxValue - minValue);
  uint8_t flags = QUALITY_OK;
  const char *tune = "hold";

  if (brightness < 72u) {
    flags |= QUALITY_DIM;
    tune = "boost_light";
  } else if (brightness > 206u) {
    flags |= QUALITY_BRIGHT;
    tune = "reduce_light";
  }

  if (contrast < 80u) {
    flags |= QUALITY_LOW_CONTRAST;
    tune = (flags & QUALITY_DIM) ? "boost_light_contrast" : "boost_contrast";
  }

  if (len > largeJpegThreshold(profileIndex)) {
    flags |= QUALITY_LARGE_JPEG;
    if (tune == nullptr || tune[0] == 'h') tune = "compress_next";
  }

  return CameraQualitySnapshot{brightness, contrast, flags, tune};
}

} // namespace ican_eye_quality
