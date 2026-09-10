# wujian100_open 代码架构分析

> 一个基于 **平头哥（T-Head）E902 RISC-V 内核**的 MCU 级 SoC 开源工程，包含 RTL、验证平台、SDK 与 FPGA 工程。

---

## 1. 项目概览

| 项目 | 说明 |
|---|---|
| CPU | 32 位 RISC-V E902 |
| 总线 | AMBA AHB 多层交叉开关 + APB |
| 片上存储 | 64KB ISRAM + 3×64KB DSRAM |
| 外设 | DMAC×1、TIM×16、GPIO×1、USI×3、RTC、PWM、WDT |
| 中断 | VIC 支持 64 级嵌套，每中断带优先级 |
| 目标 | 支持 EDA 仿真与 FPGA 原型验证 |

---

## 2. 目录结构

| 目录 | 作用 |
|---|---|
| `soc/` | SoC RTL 源码（Verilog） |
| `sdk/` | 软件 SDK（CSI 接口：core / driver / kernel / projects） |
| `tb/` | 仿真 testbench（`tb.v`、`busmnt.v`、`virtual_counter.v`） |
| `case/` | 各外设 C 测试用例 + 对应 `.v` |
| `lib/` | 仿真编译脚本、`crt0.s`、newlib 封装、linker |
| `tools/` | `run_case` 仿真脚本、`Srec2vmem`、环境配置 |
| `fpga/` | Synplify / Vivado 工程与约束 |
| `regress/` | 回归测试报告 |
| `doc/` | 用户指南（docx + md） |

---

## 3. RTL 层次结构

```
wujian100_open_top            soc/wujian100_open_top.v:11   ← 芯片顶层 + PAD 环
├── core_top                  soc/core_top.v:11
│   └── E902_20191018         soc/core_top.v:380            ← RISC-V CPU + BIU(3 个 AHB 主口)
├── pdu_top                   soc/pdu_top.v:11              ← 总线/外设域
│   ├── ahb_matrix_top        pdu_top.v:949                 ← 主 AHB 总线
│   │   └── ahb_matrix_7_12_main   matrix.v:34729           ← 7 主 × 12 从 交叉开关
│   │       └── dmac_top      ahb_matrix_top.v:870          ← DMA（既是主 M3 也是从 S6）
│   ├── ls_sub_top            pdu_top.v:1061                ← 低速 AHB（1×6）
│   │   └── ahb_matrix_1_6_sub
│   ├── apb0_sub_top          pdu_top.v:1112                ← APB0
│   │   └── csky_apb0_top     apb0.v:357  (地址译码 apb0_params.v)
│   │       ├── tim0/2/4/6_sec_top、usi0/usi2_sec_top、wdt_sec_top、pwm_sec_top
│   └── apb1_sub_top          pdu_top.v:1242                ← APB1
│       └── csky_apb1_top     apb1.v:357
│           └── tim1/3/5/7_sec_top、usi1_sec_top（+gpio/pmu/rtc 选择）
├── aou_top                   soc/aou_top.v:11              ← 常开域（Always-On）
│   ├── pmu_dummy_top         clkgen.v:11                   ← 时钟/复位生成
│   ├── gpio0_sec_top         gpio0.v:89
│   └── rtc0_sec_top          rtc.v:21
├── retu_top                  soc/retu_top.v:139            ← 存储子系统
│   └── smu_top → sms_top → sms_bank_64k_top ×4   sms.v    ← 1×ISRAM + 3×DSRAM
└── PAD_DIG_IO / PAD_OSC_IO   soc/sim_lib/*.v               ← IO/晶振 PAD
```

### 3.1 总线拓扑

**主 AHB 总线** `ahb_matrix_7_12_main`（7 主 × 12 从）：

- **主设备**：CPU M0/M1/M2、DMAC M3、Dummy M4–M6
- **从设备**：S0 ISRAM、S1 指令 dummy、S2–S4 DSRAM、S5 数据 dummy、S6 DMAC、S7–S9 dummy、S10 低速总线

**低速侧** `ls_sub_top`（1×6 AHB 交叉开关）再分出 APB0 / APB1 两条 APB 总线，由 `apb0_params.v` / `apb1_params.v` 完成叶子地址译码。

---

## 4. 地址映射

来源：`doc/wujian100_open Userguide v1.0.md` 与 `sdk/csi_driver/wujian100_open/include/soc.h:92`

| 地址范围 | 大小 | 用途 |
|---|---|---|
| `0x0000_0000` ~ `0x0000_7FFF` | 64KB | ISRAM（指令） |
| `0x2000_0000` ~ `0x2002_FFFF` | 192KB | DSRAM（数据，3×64KB） |
| `0x4000_0000` ~ `0x401F_FFFF` | 2MB | 主总线外设（DMAC） |
| `0x5000_0000` / `0x6000_0000` | — | 低速外设（APB0 / APB1） |
| `0x8000_0000` ~ `0x9FFF_FFFF` | 768MB | 主总线外设 |
| `0xE000_E000` ~ `0xE000_EFFF` | 4KB | TCIP（核内定时器/中断） |

### 外设基地址（节选）

| 外设 | 基地址 |
|---|---|
| DMAC0 | `0x4000_0000` |
| TIMER0 / TIMER2 | `0x5000_0000` / `0x6000_0000` |
| WDT | `0x5000_8000` |
| PWM | `0x5001_C000` |
| USI0 / USI1 / USI2 | `0x5002_8000` / `0x6002_8000` / `0x5002_9000` |
| GPIO0 | `0x6001_8000` |
| RTC0 | `0x6000_4000` |
| PMU | `0x6003_0000` |

---

## 5. 中断源（`soc.h` IRQn）

| IRQn | 名称 | IRQn | 名称 |
|---|---|---|---|
| 0–7 | 软/定时器/CORET 中断 | 26 | RTC |
| 16 | GPIO0 | 27 | WDT |
| 17–24 | TIM0–TIM7 | 28–30 | USI0/1/2 |
| 25 | PWM | 31 | PMU |
| 32 | DMAC0 | 33–40 | TIM8–TIM15 |

---

## 6. 软件架构（SDK）

SDK 遵循 **CSI 接口规范**，分为四层：

```
sdk/
├── csi_core/      核接口定义 + E902 实现（core_rv32.h / csi_core.h）
├── csi_driver/    CSI 驱动接口 + wujian100_open/ 具体实现（wj_*.c）
├── csi_kernel/    Rhino RTOS 移植（另含 FreeRTOS / ucos 对接）
├── board/         板级支持：board_init.c、gcc_csky.ld、pin.h
├── libs/          通用库
├── projects/      示例工程（benchmark / driver / rtos）
└── utilities/     工程配置文件
```

**启动链**：`startup.S` → `system.c` / `sys_freq.c` → `vectors.S` / `trap_c.c` → 应用

---

## 7. 验证与构建

### 仿真

```bash
# 使用 iverilog 或 vcs
../tools/run_case -sim_tool iverilog ../case/timer/timer_test.c
../tools/run_case -sim_tool vcs      ../case/timer/timer_test.c
```

- `tb/tb.v` 例化 DUT，`busmnt.v` 监视总线，`virtual_counter.v` 提供虚拟计数
- `case/` 提供 Timer / DMA / GPIO / PWM / RTC / USI / WDT 用例

### 综合 / FPGA

- 综合文件列表：`soc/wujian100_open_syn.filelist`（含 `for_iverilog` 版本）
- FPGA 流程：Synplify 综合 → Vivado 布局布线 → 下载 bit

---

## 8. 核心特征小结

- 单核 **E902**，3 个 AHB 主口，64 级中断嵌套 VIC
- **AHB 多层交叉开关 + APB** 两级总线结构
- 4 块片上 SRAM（1×64KB 指令 + 3×64KB 数据）
- 完整的 **PMU 低功耗时钟/复位门控**体系（`clkgen.v` + `aou_top` + `retu_top`）
- 软硬件协同：RTL ↔ SDK ↔ 仿真用例 ↔ FPGA 原型一体化
