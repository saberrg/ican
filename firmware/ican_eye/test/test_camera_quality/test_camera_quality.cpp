#include <unity.h>

#include "camera_quality.h"

using namespace ican_eye_quality;

void setUp() {}
void tearDown() {}

void test_dark_low_contrast_frame_boosts_light_and_contrast(void) {
  uint8_t jpeg[128];
  for (size_t i = 0; i < sizeof(jpeg); i++) jpeg[i] = 40;

  const CameraQualitySnapshot snapshot =
      analyzeJpegQuality(jpeg, sizeof(jpeg), 0);

  TEST_ASSERT_TRUE((snapshot.flags & QUALITY_DIM) != 0);
  TEST_ASSERT_TRUE((snapshot.flags & QUALITY_LOW_CONTRAST) != 0);
  TEST_ASSERT_EQUAL_STRING("boost_light_contrast", snapshot.tuneAction);
}

void test_bright_frame_reduces_light(void) {
  uint8_t jpeg[128];
  for (size_t i = 0; i < sizeof(jpeg); i++) jpeg[i] = 230;

  const CameraQualitySnapshot snapshot =
      analyzeJpegQuality(jpeg, sizeof(jpeg), 1);

  TEST_ASSERT_TRUE((snapshot.flags & QUALITY_BRIGHT) != 0);
  TEST_ASSERT_EQUAL_STRING("boost_contrast", snapshot.tuneAction);
}

void test_large_fast_jpeg_sets_size_flag(void) {
  uint8_t jpeg[25000];
  for (size_t i = 0; i < sizeof(jpeg); i++) jpeg[i] = (uint8_t)(i & 0xff);

  const CameraQualitySnapshot snapshot =
      analyzeJpegQuality(jpeg, sizeof(jpeg), 0);

  TEST_ASSERT_TRUE((snapshot.flags & QUALITY_LARGE_JPEG) != 0);
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_dark_low_contrast_frame_boosts_light_and_contrast);
  RUN_TEST(test_bright_frame_reduces_light);
  RUN_TEST(test_large_fast_jpeg_sets_size_flag);
  return UNITY_END();
}
