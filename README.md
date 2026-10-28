# wujian100_open
    wujian100_open is a MCU base SoC. We can simulate by EDA tools and emulate by FPGA. Also we can develop the IPs and software in this platform. We wish more and more developers building the open MCU ecosystem with T-Head. IC design and development should be faster simpler and more reliable
    Directory Structure
    |--Project                //open source project work directory  
      |--riscv-toolchain      //tool chain install directory download from t-head.cn
      |--wujian100_open       //wujian100_open project get from github
        |--case               //test case example for simulation
        |--doc                //wujian100_open user guide
        |--fpga               //FPGA script
        |--lib                //compile script for simulation
        |--regress            //regression result
        |--sdk                //software design kit
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
# Get ready for simulation
    the simulation flow only supports QuestaSim, everything lives in tools/:
      |--run_case       // build a case and run it, python, needs no make and no posix shell
      |--setup.sh       // bash: export TOOL_PATH and the QuestaSim vlog/vlib/vsim path
      |--setup.ps1      // same thing for PowerShell
      |--Srec2vmem.py   // srec -> test.pat converter used by the firmware build
    run_case finds the riscv toolchain and QuestaSim by itself, so sourcing the
    setup script is optional - it only helps when they sit somewhere unusual.
    1. cd wujian100_open/workdir
    2. bash:        ../tools/run_case ../case/timer/timer_test.c
       powershell:  python ..\tools\run_case ..\case\timer\timer_test.c
       cmd:         python ..\tools\run_case ..\case\timer\timer_test.c
    3. add -gui to open the GUI with all waves added
    using the setup scripts (only needed for a non-default install path):
       bash:        source tools/setup.sh          // `source` is a bash builtin
       powershell:  . .\tools\setup.ps1            // the leading dot is the equivalent
       cmd:         no equivalent, cmd cannot keep env changes - edit the defaults
                    in tools/run_case (DEFAULT_TOOLCHAIN / DEFAULT_QUESTA) instead
    options:
       -toolchain <dir>   riscv toolchain root, default D:/workbuddy/work/riscv-toolchain
       -pat <test.pat>    run a prebuilt image and skip the firmware build
       -tmax <time>       simulation time limit, default 10ms, stops a case that waits forever
       -nodump / -nomnt   disable the waveform dump / the bus monitor
    the result goes to workdir/run_case.report and is copied to regress/regress_result/<case>.report

# Get ready for FPGA bit generation
    1. make sure you have the synplify and license
    2. cd wujian100_open/fpga/synplify
    3. execute the synplify and load the wujian100_open_200t_3b.prj file
    4. input the command 'sdc2fdc' in synplify
    5. start the synplify
    6. after synplify generated the netlist we will use vivado for P&R and generated the bit file
    7. make sure you have the vivado and licese
    8. cd wujian100_open/fpga/vivado
    9. run tcl use file 'wujian100_open_200t_3b_prj.tcl'
    10. program the bit file to the fpga board
    11. enjoy the application development
# How to get the debug tool
    download from the url https://occ.t-head.cn/community/download?id=616215132330000384 
# How to get the IDE for development
    download from the url https://occ.t-head.cn/community/download?id=575997419775328256  
# How to use the sdk
wujian100_open SDK is wujian100_open software development kit, the software follows the CSI interface specification. Through the SDK users can quickly wujian100_open test and evaluation. At the same time users can refer to the SDK integration of various commonly used components and sample procedures for application development quickly form a product solution.
```
SDK directory structure:
|--sdk
 |--csi_core 	//CSI-Core related interface definition, and interface implementation on
                //E902.
 |--csi_dirver  //CSI-Driver related interface definition, and peripheral Driver
                //implementation.
 |--csi_kernel  //CSI-Kernel related interface definition, and Rhino, FreeRTOSv8.2.3
                //ucos-iii and other real-time operating system docking example code
 |--libs        //Store common library implementations
 |--projicet	//Store a variety of reference examples including benchmark test
                //program, driver example program, rtos example program. The relevant
                //project documents are also included.
 |--utilites	//Store project config files.
 |--VERSION
```
    1. Download and install the CDK
    2. Open a project using CDK, for example open the hello project:
      projects/examples/hello_world/CDK/wj100-open-hello_world.cdkproj
    3. Build the project:
    Click "project" on the toolbar,and select "build all". After successful compilation, you will see the following:

```
Build target ' wujian100_open-hello_world BuildSet '
----------Building project:[ wujian100_open-hello_world - BuildSet ]----------
make[1]: Entering directory 'D:/release/Wujian100_open-V1.0.0/Wujian100_open-V1.0.0/projects/examples/hello_world/CDK'
make[1]: Leaving directory 'D:/release/Wujian100_open-V1.0.0/Wujian100_open-V1.0.0/projects/examples/hello_world/CDK'
make[1]: Entering directory 'D:/release/Wujian100_open-V1.0.0/Wujian100_open-V1.0.0/projects/examples/hello_world/CDK'
linking...
size of target:
   text	   data	    bss	    dec	    hex	filename
  22680	   1628	   6660	  30968	   78f8	D:/release/Wujian100_open-V1.0.0/Wujian100_open-V1.0.0/projects/examples/hello_world/CDK/Obj/wujian100_open-hello_world.elf
checksum value of target:  0xE2B2C769 (491,388)
make[1]: Leaving directory 'D:/release/Wujian100_open-V1.0.0/Wujian100_open-V1.0.0/projects/examples/hello_world/CDK'
Executing Post Build commands ...
Done
====0 errors, 0 warnings, total time : 20s263ms====
```
    4. Run the project:
    Click "Debug" on the toolbar,and select "Start/Stop Debugger".
# Dicussion
    If you want to discuss about the wujian100_open project. You can scan the DingDing QR code below：
<img src="https://github.com/T-head-Semi/wujian100_open/blob/master/doc/QR_Code_Wujian100.JPG" width="485" height="640" alt="Wujian100" align=center/>

# Reference  and Thanks
    The program model of GPIO refer to the DesignWare of Synopsys 
    The program model of Timer refer to the DesignWare of Synopsys 
    The program model of WDT refer to the DesignWare of Synopsys 
