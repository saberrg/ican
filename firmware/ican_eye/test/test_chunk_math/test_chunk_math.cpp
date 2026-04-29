#include <unity.h>

#include "chunk_math.h"

using namespace ican_eye_chunk_math;

void setUp() {}
void tearDown() {}

void test_effectivePayload_default_mtu_23_is_18(void) {
  // ATT default MTU 23 → 23 - 3 - 2 = 18 payload bytes; below the cap of 240,
  // so we should get exactly 18.
  TEST_ASSERT_EQUAL_UINT32(18u, (uint32_t)effectivePayloadBytes(23));
}

void test_effectivePayload_below_overhead_is_zero(void) {
  TEST_ASSERT_EQUAL_UINT32(0u, (uint32_t)effectivePayloadBytes(4));
  TEST_ASSERT_EQUAL_UINT32(0u, (uint32_t)effectivePayloadBytes(5));
}

void test_effectivePayload_negotiated_250_is_capped_240(void) {
  // 250 - 3 - 2 = 245; cap of 240 kicks in.
  TEST_ASSERT_EQUAL_UINT32(240u, (uint32_t)effectivePayloadBytes(250));
}

void test_effectivePayload_max_mtu_is_capped_at_240(void) {
  // MTU 517 would allow 512 bytes but firmware caps at 240.
  TEST_ASSERT_EQUAL_UINT32(240u, (uint32_t)effectivePayloadBytes(517));
}

void test_effectivePayload_boundary_at_cap(void) {
  // 240 + overhead = 245: verify the cap is exactly 240 at this MTU.
  TEST_ASSERT_EQUAL_UINT32(240u, (uint32_t)effectivePayloadBytes(245));
}

void test_packSeqLE_zero(void) {
  uint8_t buf[2] = {0xAA, 0xBB};
  packSeqLE(buf, 0);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0x00, buf[1]);
}

void test_packSeqLE_little_endian(void) {
  uint8_t buf[2] = {0, 0};
  packSeqLE(buf, 0x1234);
  TEST_ASSERT_EQUAL_UINT8(0x34, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0x12, buf[1]);
}

void test_packSeqLE_max(void) {
  uint8_t buf[2] = {0, 0};
  packSeqLE(buf, 0xFFFF);
  TEST_ASSERT_EQUAL_UINT8(0xFF, buf[0]);
  TEST_ASSERT_EQUAL_UINT8(0xFF, buf[1]);
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
  // Sum the ramp across all attempts to confirm the total wait stays within a
  // few seconds even in the worst case (ESP_ERR_NO_MEM the whole way).
  int total = 0;
  const int n = maxNotifyRetries();
  for (int i = 0; i < n; i++) total += computeBackoffMs(i, true);
  // 5*20 + 10*50 + 25*100 = 100 + 500 + 2500 = 3100 ms for n=40.
  TEST_ASSERT_EQUAL_INT(3100, total);
}

void test_drain_gap_policy(void) {
  TEST_ASSERT_EQUAL_INT(16, drainGapEveryNChunks());
  TEST_ASSERT_EQUAL_INT(40, maxNotifyRetries());
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_effectivePayload_default_mtu_23_is_18);
  RUN_TEST(test_effectivePayload_below_overhead_is_zero);
  RUN_TEST(test_effectivePayload_negotiated_250_is_capped_240);
  RUN_TEST(test_effectivePayload_max_mtu_is_capped_at_240);
  RUN_TEST(test_effectivePayload_boundary_at_cap);
  RUN_TEST(test_packSeqLE_zero);
  RUN_TEST(test_packSeqLE_little_endian);
  RUN_TEST(test_packSeqLE_max);
  RUN_TEST(test_backoff_ramp_generic);
  RUN_TEST(test_backoff_ramp_no_mem_is_longer);
  RUN_TEST(test_backoff_negative_attempt_is_clamped);
  RUN_TEST(test_retry_budget_bounded);
  RUN_TEST(test_drain_gap_policy);
  return UNITY_END();
}
