# VPU 向量协处理器

> 在 wujian100_open 主 AHB 总线上新增的一个 4 路 SIMD 向量运算协处理器，
> 占用原本空置的从口 S7。RTL 位于 `soc/vpu_top.v`，用例位于 `case/vpu/`。

---

## 1. 为什么挂在 S7

主矩阵 `ahb_matrix_7_12_main` 有 12 个从口，其中 5 个原本接的是 `ahb_dummy_top`
（只会返回 0 的空壳）。空闲区间如下（`soc/matrix.v:33632` 起）：

| 从口 | 地址范围 | 原用途 |
|---|---|---|
| S7 | `0x4001_0000` ~ `0x4001_FFFF` | dummy0 |
| S8 | `0x4002_0000` ~ `0x4002_FFFF` | dummy1 |
| S9 | `0x4010_0000` ~ `0x401F_FFFF` | dummy2 |
| S11 | `0x8000_0000` ~ `0x9FFF_FFFF` | dummy3 |

选 S7 的理由：

- 64KB 窗口足够，且紧邻 DMAC（`0x4000_0000`），落在主总线上而不是 APB
- CPU 的数据访问走 M2 口，`tb/busmnt.v` 正好监视 M2，仿真判定天然可见
- 不需要改动 `matrix.v`（3.6 万行自动生成代码）——只把 `ahb_matrix_top.v` 里
  `x_main_dummy_top0` 的模块名从 `ahb_dummy_top` 换成 `vpu_top` 即可

### 实例名与端口必须保持不变

`case/addr_map/map_test.v` 用层次路径 `force` 了各 dummy 从口的 `hrdata`：

```verilog
force ...x_main_bus_top.x_main_dummy_top0.hrdata[31:0] = 32'h3;
```

因此 `vpu_top` 的**实例名仍是 `x_main_dummy_top0`**，**端口列表与 `ahb_dummy_top`
完全一致**（`haddr/hclk/hprot/hrdata/hready/hresp/hrst_b/hsel/hsize/htrans/hwdata/hwrite/intr`）。
改这两点时 `map_test` 会直接编译不过。

---

## 2. 总线接口

标准 AHB 从设备，`hready` 恒高，**每个传输占 2 拍**：

```
        T1 (地址拍)          T2 (数据拍)
haddr   有效                 已指向下一笔传输
hwrite  有效                 -
hwdata  -                    本次写数据
hrdata  -                    本次读数据
hresp   -                    本次响应
```

**这一点必须注意**：E902 会流水发传输，地址拍和数据拍是错开的。最初版本按
"同拍地址 + 数据"写，结果所有写操作的数据都比地址晚了一拍，表现为
`V0` 读到 `MASK` 的值。正确做法是把地址相位寄存下来：

```verilog
always @(posedge hclk or negedge hrst_b)
  if (!hrst_b)              a_valid <= 1'b0;
  else begin
    a_valid <= hsel & htrans[1];        // 下一拍是数据拍
    if (hsel & htrans[1]) begin
      a_addr  <= haddr;                 // 锁存地址相位
      a_write <= hwrite;
      a_size  <= hsize;
    end
  end
```

之后所有译码、读写、`hrdata`/`hresp` 都用 `a_addr`，数据用当拍的 `hwdata`。

只支持 32 位对齐字访问。`hsize != 010`、`haddr[1:0] != 0` 或超出窗口时返回
`hresp = 2'b01`（ERROR）。

时钟复位沿用 S7 原有的 `pmu_dummy0_hclk` / `pmu_dummy0_hrst_b`，在 `clkgen.v`
里就是 `soc_hclk` / `soc_hrst_b`，常开，无需改 PMU。

---

## 3. 寄存器映射

基地址 `0x4001_0000`，只支持字访问。

| 偏移 | 名称 | 属性 | 说明 |
|---|---|---|---|
| `0x000`~`0x07F` | V0~V7 | RW | 8 个向量寄存器，每个 16 字节 = 4 lane × 32bit |
| `0x080` | SCLR | RW | 标量源，`CTRL.scalar_en=1` 时广播到所有 lane |
| `0x084` | CTRL | RW | 运算控制，见下 |
| `0x088` | STATUS | RW | `[0]` busy、`[1]` done（写 1 清）、`[31:24]` 已完成运算计数 |
| `0x08C` | MASK | RW | `[3:0]` lane 写使能，复位值 `0xF` |
| `0x090` | LANES | RO | lane 数 - 1，固定 `3` |
| `0x0FC` | ID | RO | `0x5650_5531`（ASCII "VPU1"） |

向量寄存器寻址：`地址 = 0x4001_0000 + reg*16 + lane*4`，即
`V3` 的 lane2 在 `0x4001_0038`。

### CTRL 位域

| 位 | 名称 | 说明 |
|---|---|---|
| `[0]` | start | 写 1 触发一次运算，自清零 |
| `[4:1]` | op | 操作码 |
| `[7:5]` | vd | 目的寄存器号 0~7 |
| `[10:8]` | va | 源 A 寄存器号 |
| `[13:11]` | vb | 源 B 寄存器号 |
| `[14]` | scalar_en | 1 时 B 操作数改用 SCLR 广播 |

### STATUS 位域

| 位 | 说明 |
|---|---|
| `[0]` | busy，运算执行中 |
| `[1]` | done，运算完成，写 1 清除 |
| `[31:24]` | 已退休的运算条数，8 位回绕 |

---

## 4. 指令集

一次触发对**全部 4 个 lane 并行**执行同一操作，各 lane 之间没有跨 lane 通信。

| op | 助记符 | 语义 |
|---|---|---|
| 0 | VADD | `Vd = Va + Vb` |
| 1 | VSUB | `Vd = Va - Vb` |
| 2 | VAND | `Vd = Va & Vb` |
| 3 | VOR | `Vd = Va \| Vb` |
| 4 | VXOR | `Vd = Va ^ Vb` |
| 5 | VMUL | `Vd = low32(Va * Vb)` |
| 6 | VMAC | `Vd = Vd + Va * Vb`（乘累加，可反复触发做点积） |
| 7 | VMIN | 有符号取小 |
| 8 | VMAX | 有符号取大 |
| 9 | VABS | `Vd = \|Va\|`，`INT32_MIN` 饱和回自身 |
| 10 | VNEG | `Vd = -Va` |
| 11 | VSHL | `Vd = Va << Vb[4:0]`（每个 lane 自己的移位量） |
| 12 | VSHR | `Vd = Va >> Vb[4:0]`（逻辑右移） |
| 13 | VCOPY | `Vd = Va` |

`MASK` 中为 0 的 lane 保持原值不写，可以只更新向量的部分分量。

### 执行时序

```
CPU: 写 CTRL(start=1) ──┐
                        │  T0 采到写，busy <= 1
                        ├─ T1 busy=1，4 个 lane 并行算，vd_new 组合
                        ├─   T1 末 vreg[vd] <= vd_new
                        └─ T2 busy=0, done=1, ops_cnt++
软件:  轮询 STATUS[1] 后即可读 Vd
```

从 start 到结果可见是 2 拍。软件必须轮询 `done`，不能"写完立刻读"。

---

## 5. 编程模型

寄存器定义与内联小工具在 `case/vpu/vpu.h`：

```c
#include "vpu.h"

/* 写一个向量的 4 个 lane */
vpu_set_v(0, 1, 2, 3, 4);

/* 触发 V2 = V0 + V1 并等待完成，返回 0 表示成功 */
vpu_exec(VPU_F_OP(VPU_OP_VADD) | VPU_F_VD(2) | VPU_F_VA(0) | VPU_F_VB(1));

/* 读 lane1 */
x = vpu_get_lane(2, 1);
```

`vpu_exec` 内部做了三件事，顺序不能颠倒：

1. 等 `busy` 清零（上一次运算彻底退休）
2. 写 `STATUS = 2` 清掉陈旧的 `done`
3. 写 `CTRL` 带 start，再轮询 `done`

第 2 步如果漏掉，下一次运算会立刻读到上一次遗留的 `done=1`，误判为完成。

### 点积示例

用 VMAC 做 4 元素点积（`case/vpu/vpu_test.c` 第 10 段）：

```c
vpu_set_v(0, 1, 2, 3, 4);        /* A */
vpu_set_v(1, 5, 6, 7, 8);        /* B */
vpu_set_v(6, 0, 0, 0, 0);        /* 累加器清零 */
vpu_exec(VPU_F_OP(VPU_OP_VMAC) | VPU_F_VD(6) | VPU_F_VA(0) | VPU_F_VB(1));
/* V6 = [5, 12, 21, 32]，求和 70 由标量代码完成 */
```

长向量可以软件分块：每 4 个元素触发一次 VMAC，累加器始终留在 `V6`，
不需要在内存里来回搬中间结果。

---

## 6. 集成改动清单

| 文件 | 改动 |
|---|---|
| `soc/vpu_top.v` | **新增**，协处理器 RTL |
| `soc/ahb_matrix_top.v` | `x_main_dummy_top0` 的模块名 `ahb_dummy_top` → `vpu_top`，端口连接不变 |
| `soc/wujian100_open_syn.filelist` | 加 `./vpu_top.v` |
| `soc/wujian100_open_syn_for_iverilog.filelist` | 加 `../soc/vpu_top.v` |
| `case/vpu/vpu.h` | **新增**，寄存器定义 + 读写/执行封装 |
| `case/vpu/vpu_test.c` | **新增**，功能用例 |
| `doc/ARCHITECTURE.md` | 地址映射、从设备列表、RTL 层次同步 |

没有改动 `matrix.v`、`pdu_top.v`、`wujian100_open_top.v`、`clkgen.v`，
也没有新增任何顶层端口，因此对现有外设和 SDK 完全透明。

---

## 7. 验证

```bash
bash tools/run_questa.sh case/vpu/vpu_test.c
```

实测结果：

```
  id=56505531 lanes=4
  dot product = 46
  checks=4c exec=10 fail=0
VPU test successfully
RESULT: TEST PASS
```

覆盖项：ID / LANES、向量寄存器读写、VADD、VSUB、VMUL、VMAC、VAND、VOR、VXOR、
VMIN、VMAX、VABS、VNEG、VSHL、VSHR、标量广播、lane MASK、4 元点积、
STATUS 运算计数器。共 76 项断言。

回归（VPU 挂载后重跑）：

| 用例 | 结果 | 说明 |
|---|---|---|
| `case/vpu/vpu_test.c` | PASS | 新增 |
| `case/addr_map/map_test.c` | PASS | 其 `force` 依赖的实例名未变 |
| `case/timer/timer_test.c` | PASS | |
| `case/gpio/gpio_test.c` | PASS | |
| `case/had_soc/e902_had_test.c` | PASS | |

RTL 编译 35 个文件，0 error / 0 warning。

---

## 8. 已知限制与扩展方向

- **无中断输出**：`main_dummy0_intr` 在 `wujian100_open_top.v` 里没有接到 VIC，
  所以软件只能轮询 `STATUS.done`。要接中断需要把该信号引到 `core_top` 的
  `dmac_vic_if` / 中断汇总之类的位置，并占用一个空闲 IRQn。
- **只有 4 lane**：元素宽度固定 32 位。要支持 16/8 位 SIMD 需要在 `vpu_alu` 前加
  元素拆分/合并，并给 CTRL 增加 `esize` 字段。
- **没有向量 load/store**：所有数据靠 CPU 逐字搬运，这是当前最大的瓶颈。
  下一步可以让 VMAC 的两个源操作数直接从 DSRAM 读（给 VPU 加一个 AHB 主口），
  否则 4×32bit 的并行度会被 8 次标量访问抵消。
- **乘除法占资源**：4 个 32×32 乘法器会映射到 4 个 DSP，对小 FPGA 偏重，
  可以改成 1 个乘法器时分复用 4 个 lane，代价是 4 拍出结果。
- **未做形式/随机验证**：目前只有定向用例。
