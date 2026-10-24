/*
 * Copyright (C) 2017-2019 Alibaba Group Holding Limited
 */

/******************************************************************************
 * @file     main.c
 * @brief    CSI 驱动调用冒烟测试：GPIO + TIMER
 *
 * 目的：验证在 SDK 程序里可以直接调用 csi_driver 的驱动 API，并且
 *       驱动真的产生了总线访问、真正驱动了 RTL 外设。
 *
 * 验证方式：
 *   1) GPIO  —— 调 csi_gpio_pin_write() 写引脚，然后直接读回
 *               GPIO0 的 SWPORT_DR / SWPORT_DDR 寄存器；
 *               如果驱动真的写到硬件，寄存器里应该能看到对应位。
 *   2) TIMER —— 调 csi_timer_*() 让计数器自由运行，间隔读两次
 *               CNTVAL。wujian100 的 timer 是 32 位**递减**计数器，
 *               所以第二次读数应该变小。
 ******************************************************************************/

#include <stdio.h>
#include "soc.h"
#include "drv_gpio.h"
#include "drv_timer.h"
#include "pin.h"
#include "pin_name.h"

/* GPIO0 寄存器：SWPORT_DR 偏移 0x00，SWPORT_DDR 偏移 0x04 */
#define GPIO0_DR   (*(volatile uint32_t *)(WJ_GPIO0_BASE + 0x00))
#define GPIO0_DDR  (*(volatile uint32_t *)(WJ_GPIO0_BASE + 0x04))

#define PIN_BIT    (1u << EXAMPLE_GPIO_PIN)

static int fails = 0;

static void check(const char *name, int ok)
{
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", name);

    if (!ok) {
        fails++;
    }
}

/* ------------------------------------------------------------------ GPIO */
static void test_gpio(void)
{
    gpio_pin_handle_t pin;
    uint32_t          dr;
    uint32_t          ddr;
    bool              in_val = 0;
    int32_t           ret;

    printf("\n--- GPIO driver (PA%d) ---\n", EXAMPLE_GPIO_PIN);

    /* 先把 PA1 的引脚功能切到 GPIO */
    drv_pinmux_config(EXAMPLE_GPIO_PIN, EXAMPLE_GPIO_PIN_FUNC);

    pin = csi_gpio_pin_initialize(EXAMPLE_GPIO_PIN, NULL);
    check("csi_gpio_pin_initialize 返回句柄", pin != NULL);

    if (pin == NULL) {
        return;
    }

    ret = csi_gpio_pin_config_direction(pin, GPIO_DIRECTION_OUTPUT);
    check("config_direction(OUTPUT) 返回 0", ret == 0);

    ddr = GPIO0_DDR;
    printf("  SWPORT_DDR = 0x%08x\n", (unsigned int)ddr);
    check("DDR 中 PA1 方向位被置 1", (ddr & PIN_BIT) != 0);

    /* 写 1，直接读回输出数据寄存器 */
    csi_gpio_pin_write(pin, 1);
    dr = GPIO0_DR;
    printf("  write(1) -> SWPORT_DR = 0x%08x\n", (unsigned int)dr);
    check("DR 中 PA1 数据位 = 1", (dr & PIN_BIT) != 0);

    /* 写 0，确认能拉低 */
    csi_gpio_pin_write(pin, 0);
    dr = GPIO0_DR;
    printf("  write(0) -> SWPORT_DR = 0x%08x\n", (unsigned int)dr);
    check("DR 中 PA1 数据位 = 0", (dr & PIN_BIT) == 0);

    /* 驱动读的是 EXT_PORTA（焊盘输入），仿真里没有外部激励，应为 0 */
    csi_gpio_pin_read(pin, &in_val);
    printf("  csi_gpio_pin_read -> %d (EXT_PORTA，无外部激励时为 0)\n",
           (int)in_val);

    csi_gpio_pin_uninitialize(pin);
}

/* ----------------------------------------------------------------- TIMER */
static void test_timer(void)
{
    timer_handle_t timer;
    uint32_t       v1 = 0;
    uint32_t       v2 = 0;
    uint32_t       i;
    int32_t        delta;
    int32_t        ret;

    printf("\n--- TIMER driver (timer0) ---\n");

    timer = csi_timer_initialize(0, NULL);
    check("csi_timer_initialize 返回句柄", timer != NULL);

    if (timer == NULL) {
        return;
    }

    ret = csi_timer_config(timer, TIMER_MODE_FREE_RUNNING);
    check("csi_timer_config(FREE_RUNNING) 返回 0", ret == 0);

    ret = csi_timer_start(timer);
    check("csi_timer_start 返回 0", ret == 0);

    csi_timer_get_current_value(timer, &v1);

    /* 软件空转，让硬件计数往前走 */
    for (i = 0; i < 2000; i++) {
        __asm__ __volatile__("nop");
    }

    csi_timer_get_current_value(timer, &v2);

    delta = (int32_t)(v2 - v1);
    printf("  CNTVAL: %u -> %u (delta %d)\n",
           (unsigned int)v1, (unsigned int)v2, (int)delta);
    check("计数器在变化", v2 != v1);
    check("递减方向正确（delta < 0）", delta < 0);

    csi_timer_stop(timer);
    csi_timer_uninitialize(timer);
}

/* ------------------------------------------------------------------ main */
int main(void)
{
    printf("\r\n=== CSI driver smoke test ===\n");

    test_gpio();
    test_timer();

    printf("\nfails = %d\n", fails);
    printf(fails == 0 ? "DRIVER TEST PASS\n" : "DRIVER TEST FAIL\n");

    return 0;
}
