# PowerShell 版 setup.sh，用法（注意开头的点，表示在当前会话里生效）：
#     . .\tools\setup.ps1
# setup.sh 用的是 bash 的 source，PowerShell 里没有 source，对应写法是点号调用。

$WujianRoot = Split-Path -Parent $PSScriptRoot
$env:wujian100_open_PATH = "$WujianRoot\"

# ---------------------------------------------------------------- toolchain
if (-not $env:TOOL_PATH) {
    foreach ($d in @("D:\workbuddy\work\riscv-toolchain", "/opt/riscv")) {
        if ((Test-Path "$d\bin\riscv64-unknown-elf-gcc.exe") -or
            (Test-Path "$d\bin\riscv64-unknown-elf-gcc")) {
            $env:TOOL_PATH = $d
            break
        }
    }
}
if ($env:TOOL_PATH -and (Test-Path "$env:TOOL_PATH\bin")) {
    $env:PATH = "$env:TOOL_PATH\bin;$env:PATH"
} else {
    Write-Host "[setup] warning: riscv toolchain not found, pass -toolchain <dir> to run_case"
}

# ---------------------------------------------------------------- questasim
if (-not $env:QUESTA_HOME) {
    foreach ($d in @("D:\questasim64_10.6c", "C:\questasim64_10.6c",
                     "D:\questasim", "C:\questasim")) {
        foreach ($sub in @("win64", "win32", "bin")) {
            if (Test-Path "$d\$sub\vsim.exe") {
                $env:QUESTA_HOME = $d
                break
            }
        }
        if ($env:QUESTA_HOME) { break }
    }
}
if ($env:QUESTA_HOME) {
    foreach ($sub in @("win64", "win32", "bin")) {
        if (Test-Path "$env:QUESTA_HOME\$sub") {
            $env:PATH = "$env:QUESTA_HOME\$sub;$env:PATH"
        }
    }
}

$toolPath = if ($env:TOOL_PATH) { $env:TOOL_PATH } else { "<none>" }
$questaHome = if ($env:QUESTA_HOME) { $env:QUESTA_HOME } else { "<none>" }
$vsim = Get-Command vsim -ErrorAction SilentlyContinue
$vsimPath = if ($vsim) { $vsim.Source } else { "<not found>" }
$py = Get-Command python -ErrorAction SilentlyContinue
$pyPath = if ($py) { $py.Source } else { "<not found>" }

Write-Host "[setup] wujian100_open_PATH = $env:wujian100_open_PATH"
Write-Host "[setup] TOOL_PATH           = $toolPath"
Write-Host "[setup] QUESTA_HOME         = $questaHome"
Write-Host "[setup] vsim                = $vsimPath"
Write-Host "[setup] python              = $pyPath"
