#!/bin/bash
#Copyright (c) 2019 Alibaba Group Holding Limited
#
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


# bash equivalent of tools/setup.csh for WSL Ubuntu / Linux (default shell is bash)
# usage: cd wujian100_open/tools && source setup.sh


#set VCS path
#export VCS_HOME=
#export PATH=$VCS_HOME/linux/bin:$PATH

#set VCS license
#export SNPSLMD_LICENSE_FILE=

#set iverilog path (Ubuntu/WSL 默认位于 /usr/bin)
iverilog_path=/usr/bin
gtkwave_path=/usr/bin

# prepend tool dirs to PATH if not already present (equivalent of csh "set path=")
for _t in "$iverilog_path" "$gtkwave_path"; do
	case ":$PATH:" in
		*":$_t:"*) ;;
		*) PATH="$_t:$PATH" ;;
	esac
done
export PATH

#set tools path (same literal relative path as setup.csh)
export TOOL_PATH=../../riscv_toolchain


#set wujian100_open path (resolved from this script's own location)
export wujian100_open_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/wujian100_open/"
