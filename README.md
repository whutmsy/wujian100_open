# wujian100_open
    wujian100_open is a MCU base SoC. We can simulate by EDA tools and emulate by FPGA. Also we can develop the IPs and software in this platform. We wish more and more developers building the open MCU ecosystem with T-Head. IC design and development should be faster simpler and more reliable
    Directory Structure
    |--Project                //open source project work directory  
      |--riscv-toolchain      //tool chain install directory download from t-head.cn
      |--wujian100_open       //wujian100_open project get from github
        |--case               //test case example for simulation
        |--doc                //wujian100_open user guide
        |--lib                //compile script for simulation
        |--regress            //regression result
        |--soc                //Soc RTL source code
        |--tb                 //test bench
        |--tools              //simulation script and setup file
        |--workdir            //simulation directory
        |--LICENSE
        |--README.md
# Get Started
    1. prepare a project work directory just like 'Project'
    2. cd Project
    3. git clone https://github.com/T-head-Semi/wujian100_open.git or git clone git@github.com:T-head-Semi/wujian100_open.git
# Download C/C++ Compiler
    1. prepare a tool chain install directory named 'riscv-toolchain'  // use the c shell command like 'mkdir riscv-toolchain'
    2. download the tool chain from the url https://occ.t-head.cn/community/download?id=3913221581316624384
       a windows host needs the mingw build (riscv64-elf-mingw-*.tar.gz), the linux ELF build will not run there
    3. install the tool chain to the riscv-toolchain directory
# Simulation commands
    the simulation flow only supports QuestaSim, everything lives in tools/:
      |--run_case       // build a case and run it, python, needs no make and no posix shell
      |--Srec2vmem.py   // srec -> test.pat converter used by the firmware build
    run_case finds the riscv toolchain and QuestaSim by itself, so there is no
    setup script to source - it works from bash, PowerShell and cmd alike.
    when they sit somewhere unusual, either set TOOL_PATH / QUESTA_HOME, pass
    -toolchain <dir>, or edit DEFAULT_TOOLCHAIN / DEFAULT_QUESTA in tools/run_case.

    always run from workdir, it is the build and simulation directory:
      cd wujian100_open/workdir

    1. run one case
      bash:        python ../tools/run_case ../case/timer/timer_test.c
      PowerShell:  python ..\tools\run_case ..\case\timer\timer_test.c
      cmd:         python ..\tools\run_case ..\case\timer\timer_test.c

    2. run every case (full regression), 11 cases, about 10 minutes
      bash:        for c in ../case/*/*.c; do python ../tools/run_case "$c"; done

      PowerShell:  Get-ChildItem ..\case\*\*.c | ForEach-Object { python ..\tools\run_case $_.FullName }

      or one by one, with the case name and the exit code on one line:
      bash:        for c in ../case/*/*.c; do n=$(basename $(dirname "$c")); \
                     python ../tools/run_case "$c" >/dev/null; echo "$n rc=$?"; done

    3. open the GUI with all waves already added
      python ../tools/run_case -gui ../case/gpio/gpio_test.c

    4. run a prebuilt image and skip the firmware build (no toolchain needed)
      python ../tools/run_case -pat ../workdir/test.pat

    options:
       -toolchain <dir>   riscv toolchain root, default D:/workbuddy/work/riscv-toolchain
       -pat <test.pat>    use a prebuilt test.pat and skip the firmware build
       -tmax <time>       simulation time limit, default 10ms. a case waiting for a
                          stimulus that never arrives would otherwise run forever
       -nodump            disable the waveform dump
       -nomnt             disable the bus monitor of the testbench
       -gui               open the GUI and dump all waves
       -h                 full option list

    what run_case does:
       Step1  clean workdir
       Step2  copy the case sources, lib/clib and lib/newlib_wrap into workdir
       Step3  gcc -> elf -> objcopy srec -> Srec2vmem.py -> test.pat
       Step4  vlib work / vlog -mfcu / vsim

    output:
       workdir/run_case.report                    TEST PASS / TEST FAIL / NOT RUN
       workdir/<case>.elf, .obj, .hex, test.pat   build artifacts
       workdir/transcript, workdir/test.vcd       simulation transcript and waves
       regress/regress_result/<case>.report       copy of the report

    NOT RUN means the run hit -tmax before the case finished, usually a missing
    stimulus module or a clock that never starts. find out why before raising -tmax.

# How to get the debug tool
    download from the url https://occ.t-head.cn/community/download?id=616215132330000384 
# Dicussion
    If you want to discuss about the wujian100_open project. You can scan the DingDing QR code below：
<img src="https://github.com/T-head-Semi/wujian100_open/blob/master/doc/QR_Code_Wujian100.JPG" width="485" height="640" alt="Wujian100" align=center/>

# Reference  and Thanks
    The program model of GPIO refer to the DesignWare of Synopsys 
    The program model of Timer refer to the DesignWare of Synopsys 
    The program model of WDT refer to the DesignWare of Synopsys 
