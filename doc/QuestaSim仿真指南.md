# wujian100_open 本地 QuestaSim 仿真指南

> 面向 Windows 环境，使用本机 QuestaSim 10.6c 对 wujian100_open 进行 RTL 仿真。  
> 适用对象：需要在本地跑通 `case/` 下各外设用例、查看波形、或基于 RTL 调试的开发者。

---

## 1. 为什么不用上游的 run_case

上游 `tools/run_case` 已经支持 `-sim_tool questa`，但在 Windows 本机无法直接使用，原因如下：

| 依赖                        | 本机情况                                                      | 后果                  |
| ------------------------- | --------------------------------------------------------- | ------------------- |
| GNU make                  | 未安装                                                       | `Step3 (Make)` 失败   |
| `riscv64-unknown-elf-gcc` | `D:/designhouse/riscv_toolchain` 是 **Linux x86_64 ELF 版** | `Exec format error` |
| Perl                      | 有（Git 自带）                                                 | 可用                  |
| QuestaSim                 | 有（`D:/questasim64_10.6c`）                                 | 可用                  |
| WSL                       | 被安全策略列入程序黑名单                                              | 无法曲线救国              |

因此本项目新增了 `tools/run_questa.sh`：用一组直接调用的编译命令替代 `run_case` 的 make 阶段，  
其余流程（srec → `test.pat` → `vlib/vlog/vsim` → `run_case.report`）与上游保持一致。

---

## 2. 环境准备

### 2.1 QuestaSim

安装路径：`D:/questasim64_10.6c`，`win64` 目录需在 PATH 中。  
若不在 PATH，可通过环境变量指定：

```bash
export QUESTA_BIN=/d/questasim64_10.6c/win64
```

### 2.2 RISC-V 交叉编译器（Windows 版）

使用 xPack 的 `riscv-none-elf-gcc 15.2.0`，解压到：

```
D:/designhouse/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/
```

脚本会自动在以下位置查找，也可用 `RISCV_GCC` 直接指定可执行文件：

1. PATH 中的 `riscv-none-elf-gcc(.exe)` / `riscv64-unknown-elf-gcc(.exe)`
2. `../toolchains/xpack-riscv-none-elf-gcc-*/bin`
3. `/d/designhouse/toolchains/xpack-riscv-none-elf-gcc-*/bin`
4. `~/toolchains/xpack-riscv-none-elf-gcc-*/bin`

> 注意：xPack 15.2.0 的 multilib 只有 `rv32ec`，没有 `rv32emc` 目录。  
> 脚本用 `-march=rv32emc_zicsr`，gcc 会自动落到 `rv32ec/ilp32e` 的库上，  
> 生成的代码不含 M 指令（乘法/除法走 libgcc 软实现），对 E902 完全兼容。

### 2.3 Python

仅用于 `tools/Srec2vmem.py` 把 srec 转成 `test.pat`。脚本按 `python` → `python3` → `py` 顺序查找，  
也可以用 `PYTHON` 环境变量指定。

---

## 3. 快速开始

```bash
# 基本用法
bash tools/run_questa.sh case/timer/timer_test.c

# 录制波形（生成 workdir/vsim.wlf）
bash tools/run_questa.sh case/gpio/gpio_test.c --wave

# 打开图形界面
bash tools/run_questa.sh case/pwm/pwm_test.c --gui

# 关闭总线监视（tb 不例化 busmnt，没有 PASS/FAIL 判定，仅供抓波形）
bash tools/run_questa.sh case/rtc/rtc_test.c --nomnt
```

执行结束后终端会打印：

```
==> 结果: TEST PASS
RESULT: TEST PASS
```

最终判定以 `workdir/run_case.report` 为准（内容为 `TEST PASS` 或 `TEST FAIL`）。
加 `--nomnt` 时 `busmnt` 不例化，`sim_end()` 的结束标志没人捕获，仿真只能等到 `MAX_SIM_TIME`
（1.5 s 仿真时间）超时，因此**不会有有效判定**，脚本会直接打印 `RESULT: NO_MONITOR` 并返回成功。

### 3.1 参数说明

| 参数              | 说明                                 |
| --------------- | ---------------------------------- |
| `<case.c>`      | 用例文件路径，如 `case/timer/timer_test.c` |
| `--wave`        | 打开 `-voptargs=+acc` 并录制 `vsim.wlf` |
| `--gui`         | 启动 Questa 图形界面（配合 `log -r /*`）     |
| `--nomnt`       | 不例化 `busmnt`，无 PASS/FAIL 判定，仅供抓波形 |
| `-h` / `--help` | 打印帮助                               |

### 3.2 环境变量

| 变量           | 用途                        |
| ------------ | ------------------------- |
| `RISCV_GCC`  | 指定 RISC-V gcc 可执行文件       |
| `QUESTA_BIN` | 指定 QuestaSim 的 `win64` 目录 |
| `PYTHON`     | 指定 python 解释器             |

---

## 4. 脚本内部流程

```
[1/4] 准备 workdir
      清空并重建 workdir/，拷入 lib/crt0.s、linker.lcf、
      lib/clib/*、lib/newlib_wrap/*、以及用例目录下的全部文件
                          │
[2/4] 编译 + 链接
      gcc -march=rv32emc_zicsr -mabi=ilp32e ... 逐个编译 .c/.s
      ld  -Tlinker.lcf -nostartfiles -Wl,--no-relax ... -lc -lgcc -lm
                          │
[3/4] 生成 test.pat
      objcopy -O srec  →  Srec2vmem.py -i x.hex -o test.pat
                          │
[4/4] 编译 RTL + 仿真
      vlib work
      vlog -sv -timescale 1ns/100ps +define+QUESTA_SIM +define+NO_DUMP \
           +incdir+../soc/params -f ../soc/*.filelist ../tb/*.v
      vsim -c -do "run -all; quit -f" work.wujian100_open_tb [work.<case>]
```

### 4.1 workdir 产物

| 文件                          | 说明                                     |
| --------------------------- | -------------------------------------- |
| `<case>.elf` / `<case>.hex` | 编译链接产物 / srec 格式                       |
| `test.pat`                  | tb 用 `$readmemh` 加载到 ISRAM 的程序镜像       |
| `work/`                     | Questa 编译库                             |
| `run_case.report`           | 判定结果，由 `sim_end()` / `sim_fail()` 触发写入 |
| `vsim.wlf`                  | 波形（仅 `--wave`）                         |
| `transcript`                | Questa 完整日志                            |

### 4.2 程序与 tb 的交互

- `printf` 经 `lib/clib/fputc.c` + `lib/newlib_wrap/*` 输出，由 `tb/busmnt.v` 转发到终端
- `sim_end()` 向 `0x2000_7C50` 连续写两次 `0x2002` → `busmnt` 写 `TEST PASS` 并 `$finish`
- `sim_fail()` 写 `0x1001` → `TEST FAIL`
- 程序若长时间不结束，`tb.v` 的 `MAX_SIM_TIME`（1.5 s 仿真时间）会兜底判 `TEST FAIL`

---

## 5. 关键编译参数

| 参数                               | 作用 / 不加会怎样                                                |
| -------------------------------- | --------------------------------------------------------- |
| `-march=rv32emc_zicsr`           | 必须带 `zicsr`，否则 `crt0.s` 的 `csrw mtvec`、`csrr mcause` 汇编报错 |
| `-mabi=ilp32e`                   | E902 的 ABI                                                |
| `-De902` + `-Wa,--defsym=e902=1` | 分别给 C 预处理和汇编器，`crt0.s` 靠 `.ifdef e902` 选择启动流程             |
| `-Wl,--no-relax`                 | 关闭链接松弛。否则 `jal __fail` 报 `R_RISCV_RVC_JUMP` 重定位截断         |
| `-std=gnu89`                     | 代码是 2019 年的，gcc 15 的默认标准过严                                |
| `-include stdint.h`              | `lib/clib/vtimer.h` 用了 `uint32_t` 但没 include `<stdint.h>` |
| `-Wno-error=int-conversion` 等    | gcc 14+ 把这些警告升级成错误，老代码大量触发                                |
| `+define+QUESTA_SIM`             | `tb.v` 里据此选择 `integer FILE` 等写法                           |
| `+define+NO_DUMP`                | 关掉 `tb.v` 的 `$dumpfile/$dumpvars`（VCD 太大，改用 wlf）          |
| `-voptargs=+acc`                 | 仅 `--wave/--gui` 时加；不加则信号被 vopt 优化掉，wlf 只有几十 KB           |

---

## 6. 常见问题

**Q1：`Exec format error`**  
用的是 `D:/designhouse/riscv_toolchain` 里的 Linux 版工具链。改用 xPack Windows 版。

**Q2：`vlog` 报 `Macro 'TB_MODULE is undefined`**  
q10.6 的宏不跨文件传递。带 `.v` 的用例（gpio/pwm/usi）需单独编译：

```bash
vlog -sv +define+TB_MODULE=wujian100_open_tb gpio_test.v
```

脚本已自动处理。

**Q3：用例一直跑不结束，最后 `TEST FAIL`**  
多半是没加载用例自带的 `.v`。`gpio_test.v` / `pwm_test.v` / `usi_*_test.v` 是**独立顶层模块**，  
通过层次路径操作 tb 的 PAD 信号，必须和 tb 一起作为顶层：

```bash
vsim -c -do "run -all; quit -f" work.wujian100_open_tb work.gpio_test
```

脚本会在检测到同名 `.v` 时自动追加第二个顶层。

**Q4：wlf 波形文件很小、看不到信号**  
缺少 `-voptargs=+acc`，信号被 vopt 优化了。

**Q5：脚本在后台运行时静默失败**  
后台任务受沙箱限制无法写 `workdir`（`rm`/`cp` 失败），**仿真必须前台执行**。

**Q6：重启后每次都要重新编译 RTL**  
`vlog` 编译 34 个 RTL 文件约 2~4 秒，开销可以接受。若需保留，注意 `run_questa.sh` 每次会清空 `workdir`。

---

## 7. 回归结果（QuestaSim 10.6c，2026-10-17 实测）

全部 11 个用例逐个跑过（每次都是清空 `workdir` 重新编译，耗时含 RTL 编译）：

| 用例                              | 结果          | 耗时   | 备注                    |
| ------------------------------- | ----------- | ---- | --------------------- |
| `case/timer/timer_test.c`       | ✅ TEST PASS | 35 s |                       |
| `case/gpio/gpio_test.c`         | ✅ TEST PASS | 39 s | 需加载独立顶层 `gpio_test`   |
| `case/rtc/rtc_test.c`           | ✅ TEST PASS | 42 s |                       |
| `case/addr_map/map_test.c`      | ✅ TEST PASS | 43 s |                       |
| `case/pwm/pwm_test.c`           | ✅ TEST PASS | 34 s | 需加载独立顶层              |
| `case/wdt/wdt_test.c`           | ✅ TEST PASS | 38 s |                       |
| `case/usi_uart/usi_uart_test.c` | ✅ TEST PASS | 45 s | 需加载独立顶层              |
| `case/usi_spi/usi_spi_test.c`   | ✅ TEST PASS | 37 s | 需加载独立顶层              |
| `case/usi_i2c/usi_i2c_test.c`   | ✅ TEST PASS | 46 s | 需 `TOP_MODULE` 宏，见下   |
| `case/had_soc/e902_had_test.c`  | ✅ TEST PASS | 34 s |                       |
| `case/dma/dma_test.c`           | ❌ 不结束       | —    | 用例自身判定条件与 IP 不符，见下     |

RTL 本身编译干净：34 个文件，**0 error / 0 warning**，耗时约 3 秒。

### 7.1 usi_i2c：需要 `TOP_MODULE` 宏

`usi_i2c_test.v` 除了用 `` `TB_MODULE ``，还用 `` `TOP_MODULE `` 去探测
`usi1_ioctl_sd0_oe_n` 做双向 SDA 的方向仲裁。这两个宏原本只在 `tb.v` 里 `define`，
单独编译用例 `.v` 时必须同时给：

```bash
+define+TB_MODULE=wujian100_open_tb +define+TOP_MODULE=wujian100_open_tb.x_wujian100_open_top
```

只给 `TB_MODULE` 会报 `vlog-13069: near "." syntax error` 和 `Macro TOP_MODULE is undefined`，
`vsim` 随后 `Failed to find design unit`。脚本已补上第二个宏。

### 7.2 dma：数据传输成功，但状态位永远等不到 `0xe`

`dma_test.c` 结尾是 `while (int_dma_flag != 0xe) {...}`，轮询 `0x40000014`（`CHN_INT_STATUS`）。
实测该寄存器**始终为 0**，所以仿真只能跑到 `MAX_SIM_TIME`。

诊断（用例副本，仅把死循环改成有限次轮询，原用例未改）结果：

```
before: ch_en=0x0 global=0x0 status=0x0
after:  polls=20000 status=0x0
dst0=0x11111111 dst1=0x22222222 dst2=0x33333333 dst3=0x44444444
alias:  dst=0xaaaa5555 src=0x11111111     ← 改目的端不影响源端，说明是两块存储
```

结论：

- **DMA 搬运本身是正常的**——目的端拿到了源端的数据，且不是地址别名造成的
- 问题出在**状态位判定**：`chn_int_status_r` 的位定义是
  `{trgetcmp(3), htfr(2), tfr(1), err(0)}`，测试等的是 `0xe`（err+tfr+htfr+trgetcmp 同时置位）。
  单块 36 字节传输本来就不该产生半传输中断（bit2），所以即使位都正常也永远凑不齐 `0xe`
- 该用例属于上游遗留问题，**不是仿真环境或脚本的问题**。要跑通需要改用例：把等待条件改成
  `(flag & 0x2)`（传输完成）或干脆跳过状态轮询直接校验数据

诊断用的副本放在 `D:/designhouse/tmp_dma/dma_diag.c`，可随时重跑：

```bash
bash tools/run_questa.sh /d/designhouse/tmp_dma/dma_diag.c
```

---

## 8. 与上游 run_case 的对应关系

| 上游步骤                         | 本脚本             | 说明                      |
| ---------------------------- | --------------- | ----------------------- |
| Step1 清空 workdir             | `[1/4]`         | 一致                      |
| Step2 拷贝用例与库                 | `[1/4]`         | 一致                      |
| Step3 `make clean; make all` | `[2/4]` `[3/4]` | 用直接 gcc 调用 + objcopy 替代 |
| Step4 vlib/vlog/vsim         | `[4/4]`         | 一致，补充了用例顶层与宏定义          |
| 结果写 `run_case.report`        | 一致              | 由 tb 内的 `busmnt` 产生     |

上游命令与本脚本的等价关系：

```bash
# 上游（Linux + make 环境）
../tools/run_case -sim_tool questa ../case/timer/timer_test.c

# 本机
bash tools/run_questa.sh case/timer/timer_test.c
```
