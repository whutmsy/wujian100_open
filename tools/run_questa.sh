#!/usr/bin/env bash
#
# run_questa.sh - 使用本机 QuestaSim 仿真 wujian100_open
#
# 与上游 tools/run_case 的区别：
#   run_case 依赖 perl + GNU make + riscv64-unknown-elf-gcc，本机（Windows）缺少 make，
#   且自带工具链是 Linux ELF 版本。本脚本直接用 gcc/ld/objcopy 手工完成
#   "编译 -> 链接 -> srec -> test.pat"，其余仿真流程与 run_case 完全一致。
#
# 用法：
#   ./tools/run_questa.sh case/timer/timer_test.c            # 跑用例
#   ./tools/run_questa.sh case/gpio/gpio_test.c --wave       # 记录波形 vsim.wlf
#   ./tools/run_questa.sh case/pwm/pwm_test.c --gui          # 打开图形界面
#   ./tools/run_questa.sh case/timer/timer_test.c --nomnt    # 关闭总线监视
#
# 环境变量：
#   RISCV_GCC   指定 RISC-V gcc 可执行文件路径（默认自动查找）
#   QUESTA_BIN  QuestaSim bin 目录（默认在 PATH 中查找，回退到 /d/questasim64_10.6c/win64）
#   PYTHON      python 解释器（用于 Srec2vmem.py）
#
# 注意：usage() 用 `sed -n '2,22p'` 把本注释块当作帮助信息打印，
#       所以这段注释必须正好占据第 2~22 行；改动行数时要同步修改 usage()。

# -e 任一命令失败立即退出；-u 引用未定义变量即报错（防拼写错误）；
# -o pipefail 管道中任一环节失败即算失败（配合末尾的 `|| true` 放行预期内的告警）
set -euo pipefail

# ROOT 定位到仓库根目录（本脚本位于 tools/ 下），与调用时的当前目录无关；
# workdir 是仿真临时目录，已被 .gitignore 忽略，每次运行会整体清空重建
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK="$ROOT/workdir"

# ---- 命令行选项的默认值：用例文件、录波形、开 GUI、关总线监视
CASE_IN=""
WAVE=0
GUI=0
NOMNT=0

# 打印文件头部注释作为帮助：先截取第 2~22 行，再逐行去掉行首的 "# " 或 "#"
usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---- 参数解析：-h/--help 走帮助，-- 开头的是开关，其余第一个非选项参数当作用例路径
#      （用例路径只允许一个，后出现的会覆盖前一个）
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --wave)    WAVE=1 ;;
    --gui)     GUI=1 ;;
    --nomnt)   NOMNT=1 ;;
    -*)        echo "未知选项: $1"; usage 1 ;;
    *)         CASE_IN="$1" ;;
  esac
  shift
done

# ---- 参数校验：必须给用例，且文件真实存在
[ -n "$CASE_IN" ] || { echo "错误: 未指定用例"; usage 1; }
[ -f "$CASE_IN" ] || { echo "错误: 找不到用例文件 $CASE_IN"; exit 1; }

# ---- 把用例路径拆成后续要用的几段：
#      CASE_ABS 绝对路径 / CASEDIR 所在目录 / CASE_FILE 文件名
#      NAME 去扩展名（决定 elf/hex 等中间产物名，也是用例 .v 的查找依据）
#      EXT  扩展名（c 或 s/S，决定走哪条编译分支）
CASE_ABS=$(cd "$(dirname "$CASE_IN")" && pwd)/$(basename "$CASE_IN")
CASEDIR=$(dirname "$CASE_ABS")
CASE_FILE=$(basename "$CASE_ABS")
NAME="${CASE_FILE%.*}"
EXT="${CASE_FILE##*.}"

# ---------------------------------------------------------------- 工具查找
# 按优先级找 RISC-V gcc：
#   1) 环境变量 RISCV_GCC 显式指定，直接返回（信任用户，不再校验）
#   2) 已在 PATH 中的几种常见命名（xPack 用 riscv-none-elf-*，官方工具链用 riscv64-unknown-elf-*）
#   3) 常见安装目录里的 xpack-riscv-none-elf-gcc-*（路径末尾的 * 用于匹配带版本号的目录名）
# 启动失败时返回空串，由调用处报错退出
find_gcc() {
  # 环境变量优先，用户显式给了就不再猜
  [ -n "${RISCV_GCC:-}" ] && { echo "$RISCV_GCC"; return; }
  local c
  # 依次在 PATH 中探测四种可执行文件名（.exe 在前，兼容 Windows）
  for c in riscv-none-elf-gcc.exe riscv-none-elf-gcc \
           riscv64-unknown-elf-gcc.exe riscv64-unknown-elf-gcc; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return; fi
  done
  # PATH 里没有，再扫描常见安装目录（注意 -x 判断可执行，Windows 下对 .exe 同样有效）
  local d
  for d in "$ROOT"/../toolchains/xpack-riscv-none-elf-gcc-*/bin \
           /d/designhouse/toolchains/xpack-riscv-none-elf-gcc-*/bin \
           "$HOME"/toolchains/xpack-riscv-none-elf-gcc-*/bin; do
    for c in "$d/riscv-none-elf-gcc.exe" "$d/riscv-none-elf-gcc"; do
      [ -x "$c" ] && { echo "$c"; return; }
    done
  done
  echo ""
}

# 找不到编译器就没法继续，给出明确的修复提示而不是让后面的命令报奇怪错误
GCC=$(find_gcc)
[ -n "$GCC" ] || {
  echo "错误: 找不到可用的 RISC-V gcc。请设置 RISCV_GCC 环境变量。"
  exit 1
}

# ---- 从 gcc 路径推导配套的 objcopy / size：
#      先去掉 .exe 后缀，再截掉结尾的 "gcc"，剩下的就是工具链前缀（如 .../bin/riscv-none-elf-）
#      Windows 下这些工具带 .exe，所以再探测一次是否需要补后缀
PFX="${GCC%.exe}"; PFX="${PFX%gcc}"
OBJCOPY="${PFX}objcopy"; [ -x "${OBJCOPY}.exe" ] && OBJCOPY="${OBJCOPY}.exe"
SIZE="${PFX}size";       [ -x "${SIZE}.exe" ]    && SIZE="${SIZE}.exe"

# ---- 找 python（Srec2vmem.py 需要）：先看环境变量 PYTHON，再试 PATH 里的 python/python3/py
#      Windows 上 `py` 是官方启动器，通常是最后保底手段
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python python3 py; do
    command -v "$c" >/dev/null 2>&1 && { PY=$(command -v "$c"); break; }
  done
fi
[ -n "$PY" ] || { echo "错误: 找不到 python（Srec2vmem.py 需要）"; exit 1; }

# ---- Questa 可执行文件检查：PATH 里没有 vsim 时，把 QUESTA_BIN 或默认安装目录补到 PATH 前面
if ! command -v vsim >/dev/null 2>&1; then
  export PATH="${QUESTA_BIN:-/d/questasim64_10.6c/win64}:$PATH"
fi
# vlib 建库、vlog 编译、vsim 仿真，三个缺一不可，缺哪个就指名报哪个
for t in vlib vlog vsim; do
  command -v "$t" >/dev/null 2>&1 || { echo "错误: 找不到 $t，请设置 QUESTA_BIN"; exit 1; }
done

# ---- 编译参数（全脚本唯一一处定义，改这里即可全局生效）
#  -march=rv32emc_zicsr : CPU 是 RV32E + M + C，必须带 zicsr，否则 crt0.s 的 csrw mtvec 汇编报错；
#                         xPack 无 rv32emc multilib，实际会退到 rv32ec，但指令集兼容
#  -mabi=ilp32e         : RV32E 专用 ABI，只有 16 个通用寄存器
MARCH="-march=rv32emc_zicsr -mabi=ilp32e"
#  -De902               : 让 SDK 的 e902 分支生效（选择核心相关代码）
#  -O2                  : 原 Makefile 的优化级别
#  -std=gnu89           : 老代码按 gnu89 语义编译，避免新版 gcc 的严格检查
#  -include stdint.h    : 源码里直接用了 uint32_t 等类型却没 include，预置进来
#  -I.                  : 头文件都在当前 workdir（已拷贝过来）
#  后面一串 -Wno-error   : gcc 15 把很多老代码的隐式告警升级为错误，这里降级回告警
CFLAGS="-De902 -O2 -std=gnu89 -include stdint.h -I. \
-Wno-error=int-conversion -Wno-error=implicit-int \
-Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types"

# ---------------------------------------------------------------- 准备 workdir
# 每次全新重建，避免上次残留的 .o / test.pat 干扰本次结果
echo "==> [1/4] 准备 workdir"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# 拷贝启动代码与链接脚本：crt0.s 负责栈/段初始化并跳 main，linker.lcf 描述内存布局（ISRAM/DSRAM）
cp "$ROOT/lib/crt0.s" .
cp "$ROOT/lib/linker.lcf" .
# 拷贝极小 libc 实现（printf/putchar 等）和 newlib 的桩函数
cp "$ROOT/lib/clib"/*.c "$ROOT/lib/clib"/*.h .
cp "$ROOT/lib/newlib_wrap"/*.c "$ROOT/lib/newlib_wrap"/*.h .

# C 用例：整目录拷贝，这样用例自己的头文件和辅助 .c 都能被一起编进来；
#         `|| true` 是因为可能没有额外文件，不让 cp 的失败中断脚本
# S/汇编用例：只拷它自己
if [ "$EXT" = "c" ] || [ "$EXT" = "C" ]; then
  cp "$CASEDIR"/* . 2>/dev/null || true
else
  cp "$CASE_ABS" .
fi

# ---------------------------------------------------------------- 编译 + 链接
echo "==> [2/4] 编译 $NAME ($EXT)"
# crt0.s 带 --defsym=e902=1，让汇编里的 e902 条件分支生效（不同核心的寄存器定义有差异）
"$GCC" $MARCH -c crt0.s -Wa,--defsym=e902=1 -o crt0.o

if [ "$EXT" = "s" ] || [ "$EXT" = "S" ]; then
  # 汇编用例：直接汇编成 .o，不需要额外依赖 crt0 之外的源文件
  "$GCC" $MARCH $CFLAGS -c "$CASE_FILE" -o "$NAME.o"
else
  # 先编 clib / newlib_wrap / 用例目录里的其余 .c（跳过用例主文件，它留到最后编，
  # 顺序只为可读性；实际链接顺序由下面 OBJS 的拼接顺序决定）
  for f in *.c; do
    [ "$f" = "$CASE_FILE" ] && continue
    "$GCC" $MARCH $CFLAGS -c "$f" -o "${f%.c}.o"
  done
  "$GCC" $MARCH $CFLAGS -c "$CASE_FILE" -o "$NAME.o"
fi

# 收集所有 .o 但排除 crt0.o，因为链接命令里 crt0.o 要显式放在最前面（保证 _start 位于镜像起始）
OBJS=""
for f in *.o; do
  [ "$f" = "crt0.o" ] && continue
  OBJS="$OBJS $f"
done

# --no-relax: gcc 15 会为 crt0.s 里的 `jal __fail` 生成 RVC 重定位，老核不支持松弛，直接关闭
# -nostartfiles: 不用工具链自带的启动文件，用我们拷进来的 crt0.s
# -Tlinker.lcf : 按 wujian100_open 的内存布局链接（代码进 ISRAM，数据进 DSRAM）
# -lc -lgcc -lm: 仍需链接 newlib / 编译器内建库 / 数学库，缺失的符号由 clib 与 newlib_wrap 补齐
# grep -v "RWX permissions": 新版 ld 对可读写可执行段会给告警，属预期噪音，过滤掉
"$GCC" $MARCH -Tlinker.lcf -nostartfiles -Wl,--no-relax \
        crt0.o $OBJS -o "$NAME.elf" -lc -lgcc -lm 2>&1 | grep -v "RWX permissions" || true

# 链接失败时不会产生 elf，这里兜底判断（上面的 || true 会吞掉 ld 的退出码）
[ -f "$NAME.elf" ] || { echo "错误: 链接失败"; exit 1; }
echo -n "    镜像大小: "
"$SIZE" "$NAME.elf" | tail -1

# ---------------------------------------------------------------- 生成 test.pat
# 上游流程用 objcopy 生成 srec，再用 Srec2vmem.py 转成 tb 能 $readmemh 的格式。
# test.pat 就是被测程序的内存镜像，文件名由 tb.v 硬编码，不能改
echo "==> [3/4] 生成 test.pat"
"$OBJCOPY" -O srec "$NAME.elf" "$NAME.hex"
"$PY" "$ROOT/tools/Srec2vmem.py" -i "$NAME.hex" -o test.pat
echo "    test.pat 行数: $(wc -l < test.pat)"

# ---------------------------------------------------------------- 编译 RTL + 仿真
echo "==> [4/4] 编译 RTL 并仿真"
# QUESTA_SIM 让 RTL 里的仿真专用分支生效；NO_DUMP 关掉综合用的信号转储
DEFS="+define+QUESTA_SIM +define+NO_DUMP"
# --nomnt 时给 tb 定义 NO_MONITOR，tb.v 里据此不例化 busmnt.v（注意：没有 case 的 .v 需要
# 层次路径激励时才谈得上"加速"；主要收益是减日志和避免监视逻辑干扰波形观察）
[ "$NOMNT" = "1" ] && DEFS="$DEFS +define+NO_MONITOR"

# 默认只有一个顶层（SoC 的 tb）
CASE_V=""
VSIM_TOPS="work.wujian100_open_tb"
# gpio/pwm/usi 等用例带一个同名 .v，它是独立顶层模块（用层次路径操作 tb 信号），
# 必须和 wujian100_open_tb 一起作为顶层加载，否则用例会一直等不到激励。
if [ -f "$WORK/$NAME.v" ]; then
  CASE_V="$NAME.v"
  VSIM_TOPS="$VSIM_TOPS work.$NAME"
fi

# 建库后编译 RTL：两个 filelist 分别列出 RTL 源文件和仿真模型库；
# incdir 指向 soc/params（里面有 CPU 配置宏）；
# 输出只保留编译摘要（** 开头的行）和错误告警，避免刷屏
vlib work >/dev/null
vlog -sv -timescale 1ns/100ps $DEFS +incdir+../soc/params \
     -f ../soc/wujian100_open_syn_for_iverilog.filelist \
     -f ../soc/wujian100_open_lib_for_iverilog.filelist \
     ../tb/busmnt.v ../tb/tb.v ../tb/virtual_counter.v 2>&1 | \
     grep -E "^\*\*|Error|Warning|Errors:" || true

# 用例 .v 里用 `TB_MODULE / `TOP_MODULE 拼层次路径，需要单独带宏编译（q10.6 的宏不跨文件传递）。
# tb.v 里这两个宏的值分别是 wujian100_open_tb 和 wujian100_open_tb.x_wujian100_open_top，
# 这里要给出一模一样的定义；usi_i2c 的模型用到了 TOP_MODULE，只给 TB_MODULE 会报语法错
if [ -n "$CASE_V" ]; then
  vlog -sv -timescale 1ns/100ps \
       +define+TB_MODULE=wujian100_open_tb \
       +define+TOP_MODULE=wujian100_open_tb.x_wujian100_open_top \
       $CASE_V 2>&1 | grep -E "^\*\*|Error|Warning|Errors:" || true
fi

# ---- 三种运行模式
if [ "$GUI" = "1" ]; then
  # 图形界面：交给用户手动 run/看波形；log -r /* 先把全层次信号加入记录列表
  echo "    打开 Questa GUI ..."
  vsim -voptargs=+acc -do "log -r /*" $VSIM_TOPS
  exit 0
elif [ "$WAVE" = "1" ]; then
  # 批处理 + 录波形：-voptargs=+acc 必须加，否则 vopt 会把信号优化掉，wlf 只有几十 KB
  vsim -c -voptargs=+acc -wlf vsim.wlf -do "log -r /*; run -all; quit -f" $VSIM_TOPS 2>&1 | tail -30
else
  # 纯批处理：不录波形，跑得更快
  vsim -c -do "run -all; quit -f" $VSIM_TOPS 2>&1 | tail -30
fi

# ---------------------------------------------------------------- 结果判定
# 判定依据不是 printf 输出，而是 tb/busmnt.v：用例调用 sim_end() 往 0x20007c50 写 0x2002，
# busmnt 捕获后把结论写进 run_case.report 并 $finish，所以读这个文件即可
echo

# --nomnt 时 busmnt 没有被例化，没人捕获 sim_end 的结束标志，仿真只能等 tb.v 的
# MAX_SIM_TIME（1.5s 仿真时间）超时，由超时分支写一个 TEST FAIL——这个结果不代表用例失败，
# 所以这里不当作判定，只提示用户这是波形调试模式
if [ "$NOMNT" = "1" ]; then
  echo "==> 结果: 已关闭总线监视（--nomnt），无 PASS/FAIL 判定，仅供波形调试"
  echo "RESULT: NO_MONITOR"
  [ "$WAVE" = "1" ] && echo "==> 波形: $WORK/vsim.wlf (vsim -view $WORK/vsim.wlf)"
  exit 0
fi

if [ -f run_case.report ]; then
  RES=$(cat run_case.report)
  echo "==> 结果: $RES"
  # RESULT: 前缀是给批处理脚本 grep 用的稳定标记（中文在管道里可能因编码匹配不到）
  echo "RESULT: $RES"
  [ "$WAVE" = "1" ] && echo "==> 波形: $WORK/vsim.wlf (vsim -view $WORK/vsim.wlf)"
else
  # 没有 report 通常意味着仿真没跑到 sim_end：死等标志、超时被杀、或 RTL 编译失败
  echo "==> 结果: 无 run_case.report（可能超时或未执行 sim_end）"
  echo "RESULT: NO_REPORT"
  exit 1
fi
