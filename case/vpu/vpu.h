/*
 * vpu.h - register map and helper macros for the wujian100_open vector
 * coprocessor (VPU), mapped at 0x4001_0000 on main AHB slave port S7.
 *
 * The VPU has 8 vector registers, each holding 4 lanes of 32 bit.
 * One CTRL write with the start bit executes one opcode over all lanes.
 */

#ifndef __VPU_H__
#define __VPU_H__

#include "datatype.h"

#define VPU_BASE            0x40010000u

/* V0..V7: 16 bytes each, lane l of register n lives at n*16 + l*4 */
#define VPU_VREG(n)         (VPU_BASE + (((uint32_t)(n)) << 4))
#define VPU_VLANE(n, l)     (VPU_BASE + (((uint32_t)(n)) << 4) + (((uint32_t)(l)) << 2))

#define VPU_SCLR            (VPU_BASE + 0x080u)     /* scalar source        */
#define VPU_CTRL            (VPU_BASE + 0x084u)     /* control              */
#define VPU_STATUS          (VPU_BASE + 0x088u)     /* busy/done/op count   */
#define VPU_MASK            (VPU_BASE + 0x08cu)     /* per lane write mask  */
#define VPU_LANES           (VPU_BASE + 0x090u)     /* lanes - 1            */
#define VPU_ID              (VPU_BASE + 0x0fcu)     /* 0x56505531 'VPU1'    */

#define VPU_ID_VALUE        0x56505531u
#define VPU_LANE_COUNT      4u

/* opcodes */
#define VPU_OP_VADD         0
#define VPU_OP_VSUB         1
#define VPU_OP_VAND         2
#define VPU_OP_VOR          3
#define VPU_OP_VXOR         4
#define VPU_OP_VMUL         5
#define VPU_OP_VMAC         6
#define VPU_OP_VMIN         7
#define VPU_OP_VMAX         8
#define VPU_OP_VABS         9
#define VPU_OP_VNEG         10
#define VPU_OP_VSHL         11
#define VPU_OP_VSHR         12
#define VPU_OP_VCOPY        13

/* CTRL bit fields */
#define VPU_CTRL_START      (1u << 0)
#define VPU_F_OP(op)        ((((uint32_t)(op))  & 0xfu) << 1)
#define VPU_F_VD(n)         ((((uint32_t)(n))   & 0x7u) << 5)
#define VPU_F_VA(n)         ((((uint32_t)(n))   & 0x7u) << 8)
#define VPU_F_VB(n)         ((((uint32_t)(n))   & 0x7u) << 11)
#define VPU_F_SCALAR        (1u << 14)

/* STATUS bits */
#define VPU_ST_BUSY         (1u << 0)
#define VPU_ST_DONE         (1u << 1)

static uint32_t vpu_rd(uint32_t addr)
{
  return *(volatile uint32_t *)addr;
}

static void vpu_wr(uint32_t addr, uint32_t val)
{
  *(volatile uint32_t *)addr = val;
}

/* write the 4 lanes of one vector register */
static void vpu_set_v(uint32_t reg, uint32_t l0, uint32_t l1,
                      uint32_t l2, uint32_t l3)
{
  vpu_wr(VPU_VLANE(reg, 0), l0);
  vpu_wr(VPU_VLANE(reg, 1), l1);
  vpu_wr(VPU_VLANE(reg, 2), l2);
  vpu_wr(VPU_VLANE(reg, 3), l3);
}

static uint32_t vpu_get_lane(uint32_t reg, uint32_t lane)
{
  return vpu_rd(VPU_VLANE(reg, lane));
}

/*
 * Fire one operation and wait for it to retire.
 * Returns 0 on success, non zero if the VPU never reported done.
 */
static int vpu_exec(uint32_t ctrl)
{
  uint32_t st;
  uint32_t guard;

  /* make sure the previous operation has fully retired */
  guard = 0;
  do {
    st = vpu_rd(VPU_STATUS);
  } while ((st & VPU_ST_BUSY) && (++guard < 100000u));
  if (guard >= 100000u) {
    return -1;
  }

  /* clear a stale done flag, then start */
  vpu_wr(VPU_STATUS, VPU_ST_DONE);
  vpu_wr(VPU_CTRL, ctrl | VPU_CTRL_START);

  guard = 0;
  do {
    st = vpu_rd(VPU_STATUS);
  } while (!(st & VPU_ST_DONE) && (++guard < 100000u));
  if (guard >= 100000u) {
    return -2;
  }

  vpu_wr(VPU_STATUS, VPU_ST_DONE);
  return 0;
}

#endif /* __VPU_H__ */
