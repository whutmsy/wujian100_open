# SDK 工具链

`sdk/` 是上游的无剑 100 软件包（CSI-v1.7.2，平头哥 CSI 接口规范），和 `case/` 下那些裸机用例是**两套独立的软件体系**。这份文档记录它在本机怎么编、怎么跑进仿真、以及踩过的坑。

## 一、目录结构

```
sdk/
├── VERSION                 CSI-v1.7.2
├── csi_core/               内核抽象层（寄存器定义、core 接口）
├── csi_driver/
│   ├── include/            统一驱动头（drv_gpio.h / drv_usart.h ...）
│   └── wujian100_open/     本芯片的实现 + 启动代码
│       ├── startup.S       Reset_Handler、向量、.data/.bss 初始化
│       ├── vectors.S       中断向量
│       ├── trap_c.c        异常打印（printf 寄存器现场）
│       ├── system.c        时钟/系统初始化
│       ├── wj_*.c          各外设驱动（gpio/timer/usi/dma/rtc/pwm/wdt）
│       └── include/        soc.h、pin_name.h 等
├── csi_kernel/             rhino / freertos / ucos3（本工程不用）
├── libs/
│   ├── mm/ libc/ syslog/ ringbuffer/   源码形式的小组件
│   ├── libnewlib_wrap.a    预编译的 newlib 桩（printf 家族）
│   └── include/
├── board/wujian100_open_evb/
│   ├── gcc_csky.ld         链接脚本（ISRAM 0x0 64KB / SRAM 0x20000000）
│   ├── board_init.c        板级初始化
│   └── include/
├── projects/               22 个可编工程（每个目录一个 Makefile + sub.mk）
│   ├── examples/hello_world、driver/{gpio,timer,usart,spi,iic,pwm,rtc,dmac,wdt}
│   ├── examples/core/vic
│   └── benchmark/{coremark,dhrystone}
└── utilities/              aft_build.sh、gdb.init、flash.init
```

`projects/*/CDK/` 里是 `.cdkproj`，给平头哥 CDK（C-SKY Development Kit）IDE 用的工程文件。

## 二、上游的构建方式（本机跑不了）

每个 `projects/<x>/Makefile` 是自包含的，关键变量：

| 变量 | 值 |
|---|---|
| `TARGET_CPU` | `rv32emc` → `-march=rv32emc -mabi=ilp32e` |
| `SOC` / `BOARD` | `wujian100_open` / `wujian100_open_evb` |
| `KERNEL` | `none`（裸机），kernel 示例才有 rhino/freertos |
| `CC` | **写死** `riscv64-unknown-elf-gcc` |
| `LINKFILE` | `board/wujian100_open_evb/gcc_csky.ld` |
| 输出 | `out/wujian100_open_evb.elf`（+ `.asm`） |
| 库 | `libs/libnewlib_wrap.a` 用 `--whole-archive` 链入 |

本机有四个硬障碍，所以直接 `make` 必然失败：

1. **没有 GNU make**（Bash 里 `make: command not found`）。
2. 工具链前缀对不上：本机是 `riscv-none-elf-*`（xPack），Makefile 写死 `riscv64-unknown-elf-*`。
3. `startup.S` 里有 `csrw mtvt, a0` —— `mtvt` 是 E902 私有 CSR，上游 binutils 不认识，报 `unknown CSR 'mtvt'`。
4. `-march=rv32emc` 不含 `zicsr`，但启动代码用 `csrw/csrr`，需要改成 `rv32emc_zicsr`。

## 三、本机的替代方案：`tools/build_sdk.sh`

按 Makefile 的变量关系重写了一遍构建流程，不依赖 make，直接用 xPack gcc。

```bash
bash tools/build_sdk.sh --list                              # 列出 22 个工程
bash tools/build_sdk.sh sdk/projects/examples/hello_world    # 只编
bash tools/build_sdk.sh sdk/projects/examples/driver/gpio --sim   # 编 + 生成 workdir/test.pat
bash tools/build_sdk.sh sdk/projects/benchmark/dhrystone --out /d/tmp/dhry
```

它做的适配，逐条对应上面的障碍：

- **不用 make**：源文件集合按 Makefile 的规则展平 —— `libs/{mm,libc,syslog,ringbuffer}/*.c` + `csi_driver/wujian100_open/**/*.c` + `board/<BOARD>/*.c` + 工程目录自身 `*.c`，汇编取 `startup.S`/`vectors.S` 等。
- **前缀**：自动探测 `riscv-none-elf-gcc`（含 PATH、`/d/designhouse/toolchains/xpack-*`），也可用 `RISCV_GCC` 指定。
- **mtvt**：编译前把 `startup.S` 复制一份，`csrw mtvt, a0` → `csrw 0x307, a0`（mtvt 的 CSR 编号就是 0x307），写到 `out/obj/startup_patched.S`，**不改仓库源码**。
- **zicsr**：`-march=rv32emc_zicsr`（指令集兼容，只是让汇编器认 CSR 指令）。
- 另外补了 gcc 15 的一堆 `-Wno-error=...`（隐式声明、指针类型不兼容等老代码问题）。

编译结果（`hello_world`）：

```
text 26380   data 328   bss 6972        → 26KB，ISRAM 64KB 装得下
```

## 四、加载进仿真

`--sim` 做三件事：

1. 链入 `tools/sdk_sim_printf.c`，并加 `-Wl,--wrap=fputc`；
2. `objcopy -O srec` + `tools/Srec2vmem.py` 转成 `test.pat`；
3. 拷到 `workdir/test.pat`。

然后：

```bash
cd workdir
vsim -c -do "run 1ms; quit -f" work.wujian100_open_tb
```

**不要用 `run -all`**：`startup.S` 在 `main` 返回后是一条 `__exit: j __exit` 死循环，`run -all` 会一直空转到 `tb.v` 的 `MAX_SIM_TIME`（1.5 s 仿真时间），实测要跑十几分钟还没结论。`run 1ms` 两秒出结果。

实测输出（`hello_world`）：

```
# 	******START TO LOAD PROGRAM******
# Hello World!
# Errors: 0, Warnings: 0
```

`driver/gpio` 跑 `run 2ms`：

```
# 	******START TO LOAD PROGRAM******
# please change the gpio pin A1 from high to low
```

**为什么需要 `--wrap=fputc`**：SDK 的 `fputc()` 最终走 `csi_usart_putchar()`，操作的是真实 USI UART 寄存器（`0x5001_xxxx`），而仿真里的 UART 没人接收，屏幕上什么都不会有。`tb/virtual_counter.v:91` 只认「往 `0x2001FFF0` 写一个字节」这一种打印方式。`__wrap_fputc` 把输出改写到 `0x2001FFF0`，printf 就能进 transcript。

不用 `--wrap` 而自己定义 `fputc` 不行：`libnewlib_wrap.a` 是 `--whole-archive` 链进来的，重名直接撞符号。

**时间尺度**：`run 200us` 什么都看不到，`run 1ms` 才有输出 —— SDK 的启动（`.data` 搬运、`.bss` 清零）+ newlib printf 初始化比 `lib/crt0.s` + 迷你 printf 重得多。

## 五、调用驱动程序

**可以，直接调用即可**。`build_sdk.sh` 每次都把 `csi_driver/wujian100_open/` 下 18 个 `.c` 全量编进去，
再加上 `libs/{mm,libc,syslog,ringbuffer}` 和 `board/`，一共 40 个目标文件 —— 这 40 个文件与工程本身写什么无关。
所以任意工程都能 `#include "drv_xxx.h"` 后直接调 `csi_xxx_*()`，不需要改 Makefile、不需要加源文件。

代价只是体积：只用到 GPIO+TIMER 的工程比纯 `Hello World` 大 1.7 KB（28132 vs 26468），
因为未引用的驱动函数被 `-ffunction-sections` + `--gc-sections` 丢掉了。

### 头文件与实例号

```c
#include "soc.h"        /* 外设基址：WJ_GPIO0_BASE、WJ_TIMER0_BASE ... */
#include "drv_gpio.h"   /* csi_gpio_pin_* */
#include "drv_timer.h"  /* csi_timer_* */
#include "pin.h"        /* drv_pinmux_config()、EXAMPLE_GPIO_PIN */
#include "pin_name.h"   /* PA0 / PA1 ... 枚举 */
```

实例号就是 `soc.h` 里 `WJ_xxxN_BASE` 的 N。可用驱动的头文件在 `sdk/csi_driver/include/drv_*.h`：

| 头文件 | 驱动 | 仿真里有 RTL 模型 |
|---|---|---|
| `drv_gpio.h` | GPIO（APB1 `0x6001_8000`） | ✅ |
| `drv_timer.h` | TIMER0~15（APB0 `0x5000_0000`） | ✅ |
| `drv_pwm.h` / `drv_wdt.h` / `drv_rtc.h` | PWM / WDT / RTC | ✅ |
| `drv_usart.h` / `drv_spi.h` / `drv_iic.h` | USI 复用三合一 | ✅（但收发需要外部器件模型） |
| `drv_dmac.h` | DMAC | ✅ |
| `drv_aes.h` / `drv_crc.h` / `drv_sha.h` / `drv_rsa.h` / `drv_trng.h` / `drv_eflash.h` / `drv_spiflash.h` / `drv_pmu.h` / `drv_intc.h` / `drv_i2s.h` | — | ❌ 本 SoC 没有对应 RTL，调用会落到 dummy 从口 |

### 实测样例：`sdk/projects/examples/driver/hello_drv`

```bash
bash tools/build_sdk.sh sdk/projects/examples/driver/hello_drv --sim
cd workdir && vsim -c -do "run 3ms; quit -f" work.wujian100_open_tb
```

输出：

```
=== CSI driver smoke test ===
--- GPIO driver (PA1) ---
  SWPORT_DDR = 0x00000002
  write(1) -> SWPORT_DR = 0x00000002
  write(0) -> SWPORT_DR = 0x00000000
  csi_gpio_pin_read -> 0
--- TIMER driver (timer0) ---
  CNTVAL: 4279998677 -> 4279990662 (delta -8015)
fails = 0
DRIVER TEST PASS
```

两处判定思路值得记下来：

- **GPIO 写操作要读回 `SWPORT_DR` 验证，不要用 `csi_gpio_pin_read()`**。驱动读的是 `EXT_PORTA`（焊盘输入寄存器），
  仿真里 PAD 没有外部激励，恒为 0；写进去的值只体现在输出寄存器 `DR`（偏移 `0x00`）和方向寄存器 `DDR`（偏移 `0x04`）。
- **wujian100 的 timer 是 32 位递减计数器**。`csi_timer_start()` 后 `TxLoadCount = 0xffffffff`，
  `CNTVAL` 从 `0xFFFFFFFF` 往下走，所以间隔两次读数应该是**变小**，`delta < 0`。按「递增」写判定会误判。

### 仿真里调不通的几类

1. **中断型驱动**（gpio 中断、timer 超时回调、dma 完成中断）需要外部激励或时间到达，仿真里没有按键模型，
   上游示例 `example_gpio.c` 里的 `while (int_flag);` 会永远卡住。要么自己用 `INTC` 软件触发，要么改轮询。
2. **串口收发**：USI UART 的发送会真的写 `0x5002_8xxx`，但 `tb/` 里没有 UART 行为模型，
   数据出不了仿真。所以 printf 才要 `--wrap=fputc` 走 `0x2001FFF0`。
3. **SPI / IIC**：同理，没有从器件模型，`csi_spi_transfer()` 会等状态位等不到。

## 六、和 `case/` 用例的区别

| | `case/*` | `sdk/projects/*` |
|---|---|---|
| 启动 | `lib/crt0.s`（软件查表分发中断） | `csi_driver/wujian100_open/startup.S`（mtvec 向量模式 + mtvt） |
| 链接 | `lib/linker.lcf` | `board/wujian100_open_evb/gcc_csky.ld` |
| printf | `lib/clib/*` + `lib/newlib_wrap/*`，直接写 `0x2001FFF0` | `libnewlib_wrap.a` + 真实 UART，仿真需 `--wrap` |
| 结束判定 | `sim_end()` 写 `0x20007c50`，busmnt 判 PASS/FAIL | 没有这个概念，靠看输出，跑满 `MAX_SIM_TIME` 才停 |
| 规模 | 单文件用例（几千字节） | 带完整驱动栈（20~30KB） |

所以 SDK 工程**不要**用 `tools/run_questa.sh` 跑：那个脚本会把 `workdir` 清空并重新编 `case/` 的 C 文件，SDK 的 `test.pat` 会被覆盖。

## 七、已知限制

- 只支持 `KERNEL=none` 的裸机工程。`examples/kernel/*`（rhino）需要内核源码树和 `--whole-archive` 之外的一堆宏，脚本会直接拒绝。
- `--wrap=fputc` 只解决 printf。`getchar` 之类的输入通路在仿真里没有模型，SDK 里等串口输入的示例会卡住。
- `utilities/aft_build.sh`（生成 hex/bin 的后续流程）依赖 linux 工具，没有移植，本机不用。
- `sdk/*/out/` 已加进 `.gitignore`，构建产物不入库。
