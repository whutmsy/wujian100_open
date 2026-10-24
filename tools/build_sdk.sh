#!/usr/bin/env bash
#
# build_sdk.sh - 不用 make，直接用本机 RISC-V GCC 编译 sdk/projects 下的工程
#
# 为什么需要它：
#   1) sdk/projects/*/Makefile 里写死了 riscv64-unknown-elf-* 前缀，本机工具链是
#      xPack 的 riscv-none-elf-*，前缀对不上；
#   2) 本机没有 GNU make，Makefile 根本跑不起来；
#   3) startup.S 用了 E902 私有 CSR 名 mtvt，上游 binutils 不认识，会报
#      "unknown CSR `mtvt'"（这里用数字 0x307 替代）；
#   4) Makefile 用 -march=rv32emc，但 startup/trap 里有 csr 指令，需要 zicsr。
#
# 用法：
#   bash tools/build_sdk.sh --list
#   bash tools/build_sdk.sh sdk/projects/examples/hello_world
#   bash tools/build_sdk.sh sdk/projects/examples/driver/gpio --sim
#   bash tools/build_sdk.sh sdk/projects/benchmark/dhrystone --out /d/tmp/dhry
#
# 选项：
#   --list      列出所有可编工程
#   --sim       额外把 ELF 转成 workdir/test.pat，并把 printf 重定向到仿真
#               （用 -Wl,--wrap=fputc，见 tools/sdk_sim_printf.c），可以直接
#               'cd workdir && vsim -c -do "run -all; quit -f" work.wujian100_open_tb' 跑
#   --out DIR   产物目录，默认 sdk/<工程>/out
#
# 注意：sdk_sim_printf.c 会把 printf 输出到 0x2001FFF0，由 tb/virtual_counter.v 打印；
#       硬件上这个地址不接 UART，做 FPGA 时要改成真实的 USI UART 输出。

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK="$ROOT/sdk"
BOARD=wujian100_open_evb
SOC=wujian100_open
TARGET_CPU=rv32emc_zicsr          # Makefile 里是 rv32emc，见文件头说明
LIST=0
SIM=0
OUTDIR=""
PRJ=""

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --sim)  SIM=1 ;;
    --out)  shift; OUTDIR="$1" ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知选项: $1"; exit 1 ;;
    *) PRJ="$1" ;;
  esac
  shift
done

if [ "$LIST" = "1" ]; then
  echo "可编工程（$(find "$SDK/projects" -name Makefile | wc -l) 个）："
  ( cd "$SDK" && find projects -name Makefile | sed 's#/Makefile$##' | sort | sed 's/^/  /' )
  exit 0
fi

[ -n "$PRJ" ] || { echo "错误: 未指定工程目录，用 --list 查看"; exit 1; }
# 允许写 sdk/projects/xxx 或 projects/xxx 或绝对路径
for cand in "$PRJ" "$ROOT/$PRJ" "$SDK/$PRJ" "$SDK/projects/$PRJ"; do
  [ -d "$cand" ] && { PRJ=$(cd "$cand" && pwd); break; }
done
[ -f "$PRJ/Makefile" ] || { echo "错误: $PRJ 下没有 Makefile"; exit 1; }

# ---------------------------------------------------------------- 工具链
GCC=${RISCV_GCC:-}
if [ -z "$GCC" ]; then
  for c in riscv-none-elf-gcc.exe riscv-none-elf-gcc \
           riscv64-unknown-elf-gcc.exe riscv64-unknown-elf-gcc; do
    command -v "$c" >/dev/null 2>&1 && { GCC=$(command -v "$c"); break; }
  done
fi
if [ -z "$GCC" ]; then
  for d in "$ROOT"/../toolchains/xpack-riscv-none-elf-gcc-*/bin \
           /d/designhouse/toolchains/xpack-riscv-none-elf-gcc-*/bin; do
    for c in "$d/riscv-none-elf-gcc.exe" "$d/riscv-none-elf-gcc"; do
      [ -x "$c" ] && { GCC="$c"; break 2; }
    done
  done
fi
[ -n "$GCC" ] || { echo "错误: 找不到 RISC-V gcc，用 RISCV_GCC 指定"; exit 1; }
PFX="${GCC%.exe}"; PFX="${PFX%gcc}"          # 得到 .../bin/riscv-none-elf- 前缀
EXE=""; [ -f "${PFX}objcopy.exe" ] && EXE=".exe"
OBJCOPY="${PFX}objcopy$EXE"
SIZE="${PFX}size$EXE"
PY=${PYTHON:-}
if [ -z "$PY" ]; then
  for c in python python3 py; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
fi

echo "==> 工程: ${PRJ#$ROOT/}"
echo "==> 工具链: $GCC"

NAME=$(sed -n 's/^NAME *= *//p' "$PRJ/Makefile" | head -1); NAME=${NAME:-demo}
KERNEL=$(sed -n 's/^KERNEL *= *//p' "$PRJ/Makefile" | head -1); KERNEL=${KERNEL:-none}
LINKFILE=$(sed -n 's/^LINKFILE *= *//p' "$PRJ/Makefile" | head -1); LINKFILE=${LINKFILE:-gcc_csky.ld}
if [ "$KERNEL" != "none" ]; then
  echo "错误: 该工程 KERNEL=$KERNEL，需要内核源码与链接脚本，本脚本只支持 KERNEL=none 的裸机工程"; exit 1
fi

OUT=${OUTDIR:-$PRJ/out}
OBJ=$OUT/obj
rm -rf "$OUT"; mkdir -p "$OBJ"

INC="-I$PRJ -I$PRJ/configs \
     -I$SDK/csi_core/include -I$SDK/csi_driver/include \
     -I$SDK/csi_driver/$SOC/include -I$SDK/libs/include \
     -I$SDK/board/$BOARD/include"

CFLAGS="-g -Os -march=$TARGET_CPU -mabi=ilp32e -c \
-ffunction-sections -fdata-sections -Wall \
-Wno-error=int-conversion -Wno-error=implicit-int \
-Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types \
-Wno-error=return-mismatch -Wno-error=misleading-indentation \
$INC"

SRCS=$(find "$SDK/libs/mm" "$SDK/libs/libc" "$SDK/libs/syslog" "$SDK/libs/ringbuffer" \
            "$SDK/csi_driver/$SOC" "$SDK/board/$BOARD" "$PRJ" \
            -maxdepth 1 -name '*.c' 2>/dev/null)
ASMS=$(find "$SDK/csi_driver/$SOC" -maxdepth 1 -name '*.S' 2>/dev/null)

# startup.S 的 mtvt 是 E902 私有 CSR，换成数字编号（0x307），上游 binutils 才认
sed 's/csrw\( *\)mtvt,\( *\)a0/csrw\10x307,\2a0/' \
    "$SDK/csi_driver/$SOC/startup.S" > "$OBJ/startup_patched.S"
ASMS=$(echo "$ASMS" | tr ' ' '\n' | grep -v 'startup\.S$')
ASMS="$OBJ/startup_patched.S
$ASMS"

OBJS=""
OK=0; FAIL=0
for f in $SRCS $ASMS; do
  base=$(echo "${f%.*}" | sed "s#$SDK/##; s#[/\\.]#_#g")
  o="$OBJ/$base.o"
  if ! "$GCC" $CFLAGS -o "$o" "$f" 2> "$OBJ/err.txt"; then
    FAIL=$((FAIL+1)); echo "  FAIL $(basename "$f")"; head -3 "$OBJ/err.txt" | sed 's/^/       /'
    continue
  fi
  OK=$((OK+1)); OBJS="$OBJS $o"
done
echo "==> 编译: ok=$OK fail=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "错误: 有源文件编不过"; exit 2; }

LDFLAGS="-march=$TARGET_CPU -mabi=ilp32e -nostartfiles -Wl,-T$SDK/board/$BOARD/$LINKFILE"
if [ "$SIM" = "1" ]; then
  "$GCC" $CFLAGS -o "$OBJ/sdk_sim_printf.o" "$ROOT/tools/sdk_sim_printf.c" || exit 3
  OBJS="$OBJS $OBJ/sdk_sim_printf.o"
  LDFLAGS="$LDFLAGS -Wl,--wrap=fputc"
fi

"$GCC" $LDFLAGS -o "$OUT/$NAME.elf" $OBJS \
  -Wl,--whole-archive "$SDK/libs/libnewlib_wrap.a" -Wl,--no-whole-archive \
  -lm -lc -lgcc -Wl,-gc-sections -Wl,-zmax-page-size=1024 2>&1 | head -20
[ -f "$OUT/$NAME.elf" ] || { echo "错误: 链接失败"; exit 4; }

echo "==> 产物: $OUT/$NAME.elf"
"$SIZE" "$OUT/$NAME.elf" | tail -1 | sed 's/^/    /'

if [ "$SIM" = "1" ]; then
  "$OBJCOPY" -O srec "$OUT/$NAME.elf" "$OUT/$NAME.hex"
  "$PY" "$ROOT/tools/Srec2vmem.py" -i "$OUT/$NAME.hex" -o "$OUT/test.pat"
  mkdir -p "$ROOT/workdir"
  cp "$OUT/test.pat" "$ROOT/workdir/test.pat"
  echo "==> 已就位: workdir/test.pat ($(wc -l < "$OUT/test.pat") 行)"
  echo "    跑法: cd workdir && vsim -c -do \"run 1ms; quit -f\" work.wujian100_open_tb"
  echo "    （驱动类工程给 3ms；work 库不存在时先跑一次 bash tools/run_questa.sh case/timer/timer_test.c）"
fi
