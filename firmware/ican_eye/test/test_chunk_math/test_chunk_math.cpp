#include <unity.h>

#include "chunk_math.h"

using namespace ican_eye_chunk_math;

void setUp() {}
void tearDown() {}

void test_effectivePayload_default_mtu_23_is_16(void) {
  TEST_ASSERT_EQUAL_UINT32(16u, (uint32_t)effectivePayloadBytes(23));
}

void test_effectivePayload_below_overhead_is_zero(void) {
  TEST_ASSERT_EQUAL_UINT32(0u, (uint32_t)effectivePayloadBytes(4));
  TEST_ASSERT_EQUAL_UINT32(0u, (uint32_t)effectivePayloadBytes(7));
}

void test_effectivePayload_negotiated_250_is_capped_240(void) {
  TEST_ASSERT_EQUAL_UINT32(240u, (uint32_t)effectivePayloadBytes(250));
}

void test_effectivePayload_max_mtu_is_capped_at_240(void) {
  TEST_ASSERT_EQUAL_UINT32(240u, (uint32_t)effectivePayloadBytes(517));
}

void test_effectivePayload_boundary_at_cap(void) {
  TEST_ASSERT_EQUAL_UINT32(240u, (uint32_t)effectivePayloadBytes(247));
}

void test_packSeqLE_zero(void) {
  uint8_t buf[4] = {0xAA, 0xBB, 0xCC, 0xDD};
  packSeqLE(buf, 0);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[1]);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[2]);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[3]);
}

void test_packSeqLE_little_endian(void) {
  uint8_t buf[4] = {0, 0, 0, 0};
  packSeqLE(buf, 0x1234);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[1]);
  TEST_ASSERT_EQUAL_UINT8(0x34, buf[2]);
  TEST_ASSERT_EQUAL_UINT8(0x12, buf[3]);
}

void test_packSeqLE_max(void) {
  uint8_t buf[4] = {0, 0, 0, 0};
  packSeqLE(buf, 0xFFFF);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[1]);
  TEST_ASSERT_EQUAL_UINT8(0xFF, buf[2]);
  TEST_ASSERT_EQUAL_UINT8(0xFF, buf[3]);
}

void test_packFrameSeqLE_little_endian(void) {
  uint8_t buf[4] = {0, 0, 0, 0};
  packFrameSeqLE(buf, 0x1234, 0xABCD);
  TEST_ASSERT_EQUAL_UINT8(0x34, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0x12, buf[1]);
  TEST_ASSERT_EQUAL_UINT8(0xCD, buf[2]);
  TEST_ASSERT_EQUAL_UINT8(0xAB, buf[3]);
}

void test_backoff_ramp_generic(void) {
  TEST_ASSERT_EQUAL_INT(5, computeBackoffMs(0, false));
  TEST_ASSERT_EQUAL_INT(5, computeBackoffMs(4, false));
  TEST_ASSERT_EQUAL_INT(20, computeBackoffMs(5, false));
  TEST_ASSERT_EQUAL_INT(20, computeBackoffMs(14, false));
  TEST_ASSERT_EQUAL_INT(50, computeBackoffMs(15, false));
  TEST_ASSERT_EQUAL_INT(50, computeBackoffMs(39, false));
}

void test_backoff_ramp_no_mem_is_longer(void) {
  TEST_ASSERT_EQUAL_INT(20, computeBackoffMs(0, true));
  TEST_ASSERT_EQUAL_INT(20, computeBackoffMs(4, true));
  TEST_ASSERT_EQUAL_INT(50, computeBackoffMs(5, true));
  TEST_ASSERT_EQUAL_INT(50, computeBackoffMs(14, true));
  TEST_ASSERT_EQUAL_INT(100, computeBackoffMs(15, true));
  TEST_ASSERT_EQUAL_INT(100, computeBackoffMs(39, true));
}

void test_backoff_negative_attempt_is_clamped(void) {
  TEST_ASSERT_EQUAL_INT(5, computeBackoffMs(-3, false));
  TEST_ASSERT_EQUAL_INT(20, computeBackoffMs(-1, true));
}

void test_retry_budget_bounded(void) {
  int total = 0;
  const int n = maxNotifyRetries();
  for (int i = 0; i < n; i++) total += computeBackoffMs(i, true);
  TEST_ASSERT_EQUAL_INT(3100, total);
}

void test_drain_gap_policy(void) {
  TEST_ASSERT_EQUAL_INT(16, drainGapEveryNChunks());
  TEST_ASSERT_EQUAL_INT(40, maxNotifyRetries());
}

void test_apple_connection_params_policy(void) {
  TEST_ASSERT_TRUE(appleConnectionParamsAreValid(24, 36, 0, 600));
  TEST_ASSERT_FALSE(appleConnectionParamsAreValid(24, 40, 0, 800));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_effectivePayload_default_mtu_23_is_16);
  RUN_TEST(test_effectivePayload_below_overhead_is_zero);
  RUN_TEST(test_effectivePayload_negotiated_250_is_capped_240);
  RUN_TEST(test_effectivePayload_max_mtu_is_capped_at_240);
  RUN_TEST(test_effectivePayload_boundary_at_cap);
  RUN_TEST(test_packSeqLE_zero);
  RUN_TEST(test_packSeqLE_little_endian);
  RUN_TEST(test_packSeqLE_max);
  RUN_TEST(test_packFrameSeqLE_little_endian);
  RUN_TEST(test_backoff_ramp_generic);
  RUN_TEST(test_backoff_ramp_no_mem_is_longer);
  RUN_TEST(test_backoff_negative_attempt_is_clamped);
  RUN_TEST(test_retry_budget_bounded);
  RUN_TEST(test_drain_gap_policy);
  RUN_TEST(test_apple_connection_params_policy);
  return UNITY_END();
}
