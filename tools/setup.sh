#Copyright (c) 2019 Alibaba Group Holding Limited
#
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# environment for the QuestaSim flow (git bash / msys2, linux)
# usage:  source tools/setup.sh
#
# Sets up the two things run_case needs:
#   TOOL_PATH   riscv toolchain root (bin/riscv64-unknown-elf-gcc)
#   PATH        vlog / vlib / vsim of QuestaSim

WUJIAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export wujian100_open_PATH="$WUJIAN_ROOT/"

# ---------------------------------------------------------------- toolchain
# override with:  TOOL_PATH=/your/toolchain source tools/setup.sh
if [ -z "$TOOL_PATH" ]; then
    for d in /d/workbuddy/work/riscv-toolchain /opt/riscv; do
        if [ -f "$d/bin/riscv64-unknown-elf-gcc" ] \
        || [ -f "$d/bin/riscv64-unknown-elf-gcc.exe" ]; then
            TOOL_PATH="$d"
            break
        fi
    done
fi
if [ -n "$TOOL_PATH" ] && [ -d "$TOOL_PATH/bin" ]; then
    export TOOL_PATH
    export PATH="$TOOL_PATH/bin:$PATH"
else
    echo "[setup] warning: riscv toolchain not found, pass -toolchain <dir> to run_case"
fi

# ---------------------------------------------------------------- questasim
# override with:  QUESTA_HOME=/your/questa source tools/setup.sh
if [ -z "$QUESTA_HOME" ]; then
    for d in /d/questasim64_10.6c /d/questasim /c/questasim64_10.6c \
             /c/questasim /opt/questa /opt/modelsim; do
        if [ -d "$d/win64" ] || [ -d "$d/win32" ] || [ -d "$d/bin" ]; then
            QUESTA_HOME="$d"
            break
        fi
    done
fi
if [ -n "$QUESTA_HOME" ]; then
    export QUESTA_HOME
    for sub in win64 win32 bin; do
        if [ -d "$QUESTA_HOME/$sub" ]; then
            export PATH="$QUESTA_HOME/$sub:$PATH"
        fi
    done
fi

echo "[setup] wujian100_open_PATH = $wujian100_open_PATH"
echo "[setup] TOOL_PATH           = ${TOOL_PATH:-<none>}"
echo "[setup] QUESTA_HOME         = ${QUESTA_HOME:-<none>}"
echo "[setup] vsim                = $(command -v vsim || echo '<not found>')"
echo "[setup] python              = $(command -v python || command -v python3 || echo '<not found>')"
