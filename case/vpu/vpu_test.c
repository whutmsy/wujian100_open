/*
 * vpu_test.c - functional test for the vector coprocessor (VPU)
 *
 * The VPU sits on main AHB slave port S7, base address 0x4001_0000.
 * It provides 8 vector registers of 4 x 32 bit lanes each and executes
 * one opcode across all lanes per CTRL.start trigger.
 *
 * Covered here:
 *   - ID / lane count identification
 *   - vector register read back
 *   - VADD VSUB VMUL VMAC
 *   - VAND VOR VXOR
 *   - VMIN VMAX VABS VNEG
 *   - VSHL VSHR
 *   - scalar broadcast from SCLR
 *   - per lane MASK
 *   - a 4 element dot product built out of VMAC
 *   - the retired operation counter in STATUS
 *
 * Any mismatch prints the offending lane and finally calls sim_fail(),
 * which makes the bus monitor write TEST FAIL to run_case.report.
 */

#include "stdio.h"
#include "vtimer.h"
#include "datatype.h"
#include "vpu.h"

static uint32_t fail_cnt = 0;
static uint32_t chk_cnt  = 0;
static uint32_t exec_cnt = 0;

static void chk(const char *name, uint32_t got, uint32_t exp)
{
  chk_cnt++;
  if (got != exp) {
    fail_cnt++;
    printf("  [FAIL] %s exp=%08x got=%08x\n", name, exp, got);
  }
}

static void chk_v4(const char *name, uint32_t reg,
                   uint32_t e0, uint32_t e1, uint32_t e2, uint32_t e3)
{
  uint32_t got[4];
  uint32_t exp[4];
  uint32_t i;

  got[0] = vpu_get_lane(reg, 0);
  got[1] = vpu_get_lane(reg, 1);
  got[2] = vpu_get_lane(reg, 2);
  got[3] = vpu_get_lane(reg, 3);

  exp[0] = e0;
  exp[1] = e1;
  exp[2] = e2;
  exp[3] = e3;

  for (i = 0; i < 4u; i++) {
    chk_cnt++;
    if (got[i] != exp[i]) {
      fail_cnt++;
      printf("  [FAIL] %s lane%x exp=%08x got=%08x\n", name, i, exp[i], got[i]);
    }
  }
}

/* fire one op and abort the whole test if the vpu stops responding */
#define VPU_RUN(ctrl)                                          \
  do {                                                         \
    if (vpu_exec(ctrl) != 0) {                                  \
      printf("  [FAIL] VPU no done response\n");                \
      sim_fail();                                               \
    }                                                           \
    exec_cnt++;                                                 \
  } while (0)

int main (void)
{
  uint32_t id;
  uint32_t lanes;
  uint32_t ops_start;
  uint32_t ops_end;
  uint32_t dot;
  uint32_t i;

  printf("\n===== VPU test start =====\n");

  /* ---------------------------------------------------------------- */
  /* 1. identification                                                 */
  /* ---------------------------------------------------------------- */
  id    = vpu_rd(VPU_ID);
  lanes = vpu_rd(VPU_LANES);
  chk("ID", id, VPU_ID_VALUE);
  chk("LANES-1", lanes, VPU_LANE_COUNT - 1u);
  printf("  id=%08x lanes=%x\n", id, lanes + 1u);

  ops_start = (vpu_rd(VPU_STATUS) >> 24) & 0xffu;

  vpu_wr(VPU_MASK, 0xfu);            /* all lanes enabled */

  /* ---------------------------------------------------------------- */
  /* 2. register file read back                                        */
  /* ---------------------------------------------------------------- */
  vpu_set_v(0, 1u, 2u, 3u, 4u);
  vpu_set_v(1, 10u, 20u, 30u, 40u);
  chk_v4("VREG V0", 0, 1u, 2u, 3u, 4u);
  chk_v4("VREG V1", 1, 10u, 20u, 30u, 40u);

  /* ---------------------------------------------------------------- */
  /* 3. arithmetic: VADD VSUB VMUL VMAC                                */
  /* ---------------------------------------------------------------- */
  VPU_RUN(VPU_F_OP(VPU_OP_VADD) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VADD  V0+V1", 2, 11u, 22u, 33u, 44u);

  VPU_RUN(VPU_F_OP(VPU_OP_VSUB) | VPU_F_VD(2) | VPU_F_VA(1) | VPU_F_VB(0));
  chk_v4("VSUB  V1-V0", 2, 9u, 18u, 27u, 36u);

  VPU_RUN(VPU_F_OP(VPU_OP_VMUL) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VMUL  V0*V1", 2, 10u, 40u, 90u, 160u);

  vpu_set_v(2, 1u, 1u, 1u, 1u);
  VPU_RUN(VPU_F_OP(VPU_OP_VMAC) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VMAC  1+V0*V1", 2, 11u, 41u, 91u, 161u);

  /* ---------------------------------------------------------------- */
  /* 4. bitwise                                                        */
  /* ---------------------------------------------------------------- */
  vpu_set_v(3, 0xf0f0f0f0u, 0xf0f0f0f0u, 0xf0f0f0f0u, 0xf0f0f0f0u);
  vpu_set_v(4, 0x0ff00ff0u, 0x0ff00ff0u, 0x0ff00ff0u, 0x0ff00ff0u);

  VPU_RUN(VPU_F_OP(VPU_OP_VAND) | VPU_F_VD(5) | VPU_F_VA(3) | VPU_F_VB(4));
  chk_v4("VAND", 5, 0x00f000f0u, 0x00f000f0u, 0x00f000f0u, 0x00f000f0u);

  VPU_RUN(VPU_F_OP(VPU_OP_VOR) | VPU_F_VD(5) | VPU_F_VA(3) | VPU_F_VB(4));
  chk_v4("VOR", 5, 0xfff0fff0u, 0xfff0fff0u, 0xfff0fff0u, 0xfff0fff0u);

  VPU_RUN(VPU_F_OP(VPU_OP_VXOR) | VPU_F_VD(5) | VPU_F_VA(3) | VPU_F_VB(4));
  chk_v4("VXOR", 5, 0xff00ff00u, 0xff00ff00u, 0xff00ff00u, 0xff00ff00u);

  /* ---------------------------------------------------------------- */
  /* 5. signed min / max                                               */
  /*    V0 = [-5, 7, -9, 100]  V1 = [3, -8, 12, 50]                    */
  /* ---------------------------------------------------------------- */
  vpu_set_v(0, 0xfffffffbu, 7u, 0xfffffff7u, 100u);
  vpu_set_v(1, 3u, 0xfffffff8u, 12u, 50u);

  VPU_RUN(VPU_F_OP(VPU_OP_VMIN) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VMIN", 2, 0xfffffffbu, 0xfffffff8u, 0xfffffff7u, 50u);

  VPU_RUN(VPU_F_OP(VPU_OP_VMAX) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VMAX", 2, 3u, 7u, 12u, 100u);

  /* ---------------------------------------------------------------- */
  /* 6. VABS / VNEG                                                    */
  /* ---------------------------------------------------------------- */
  vpu_set_v(0, 0xffffffffu, 5u, 0xfffffff9u, 0u);

  VPU_RUN(VPU_F_OP(VPU_OP_VABS) | VPU_F_VD(2) | VPU_F_VA(0));
  chk_v4("VABS", 2, 1u, 5u, 7u, 0u);

  VPU_RUN(VPU_F_OP(VPU_OP_VNEG) | VPU_F_VD(2) | VPU_F_VA(0));
  chk_v4("VNEG", 2, 1u, 0xfffffffbu, 7u, 0u);

  /* ---------------------------------------------------------------- */
  /* 7. shifts, amount comes from Vb per lane                          */
  /* ---------------------------------------------------------------- */
  vpu_set_v(0, 1u, 2u, 4u, 8u);
  vpu_set_v(1, 1u, 2u, 3u, 4u);

  VPU_RUN(VPU_F_OP(VPU_OP_VSHL) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VSHL", 2, 2u, 8u, 32u, 128u);

  vpu_set_v(0, 16u, 32u, 64u, 128u);
  VPU_RUN(VPU_F_OP(VPU_OP_VSHR) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VSHR", 2, 8u, 8u, 8u, 8u);

  /* ---------------------------------------------------------------- */
  /* 8. scalar broadcast: Vd = Va + 100 for every lane                  */
  /* ---------------------------------------------------------------- */
  vpu_set_v(0, 1u, 2u, 3u, 4u);
  vpu_wr(VPU_SCLR, 100u);
  VPU_RUN(VPU_F_OP(VPU_OP_VADD) | VPU_F_VD(2) | VPU_F_VA(0) |
          VPU_F_VB(1) | VPU_F_SCALAR);
  chk_v4("VADD scalar", 2, 101u, 102u, 103u, 104u);

  /* ---------------------------------------------------------------- */
  /* 9. per lane MASK: only lane0 and lane2 are written                */
  /* ---------------------------------------------------------------- */
  vpu_set_v(5, 7u, 7u, 7u, 7u);
  vpu_set_v(0, 1u, 1u, 1u, 1u);
  vpu_set_v(1, 9u, 9u, 9u, 9u);
  vpu_wr(VPU_MASK, 0x5u);
  VPU_RUN(VPU_F_OP(VPU_OP_VADD) | VPU_F_VD(5) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VADD masked", 5, 10u, 7u, 10u, 7u);
  vpu_wr(VPU_MASK, 0xfu);

  /* ---------------------------------------------------------------- */
  /* 10. dot product of A=[1,2,3,4] and B=[5,6,7,8] via VMAC            */
  /*     per lane products are 5, 12, 21, 32, total 70                 */
  /* ---------------------------------------------------------------- */
  vpu_set_v(0, 1u, 2u, 3u, 4u);
  vpu_set_v(1, 5u, 6u, 7u, 8u);
  vpu_set_v(6, 0u, 0u, 0u, 0u);
  VPU_RUN(VPU_F_OP(VPU_OP_VMAC) | VPU_F_VD(6) | VPU_F_VA(0) | VPU_F_VB(1));
  chk_v4("VDP products", 6, 5u, 12u, 21u, 32u);

  dot = 0u;
  for (i = 0; i < 4u; i++) {
    dot += vpu_get_lane(6, i);
  }
  chk("VDP sum", dot, 70u);
  printf("  dot product = %x\n", dot);

  /* ---------------------------------------------------------------- */
  /* 11. retired operation counter                                     */
  /* ---------------------------------------------------------------- */
  ops_end = (vpu_rd(VPU_STATUS) >> 24) & 0xffu;
  chk("OPS counter", (ops_end - ops_start) & 0xffu, exec_cnt & 0xffu);

  /* ---------------------------------------------------------------- */
  /* summary                                                           */
  /* ---------------------------------------------------------------- */
  printf("  checks=%x exec=%x fail=%x\n", chk_cnt, exec_cnt, fail_cnt);

  if (fail_cnt != 0u) {
    printf("VPU test failed\n");
    sim_fail();
  }

  printf("VPU test successfully\n");
  sim_end();
}
