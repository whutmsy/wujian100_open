/*
 * vpu_top.v - lightweight vector (SIMD) coprocessor for wujian100_open
 *
 * Hung off the main AHB matrix slave port S7 (base address 0x4001_0000).
 * The port list is intentionally identical to ahb_dummy_top so that the
 * matrix instantiation and the existing hierarchical references in
 * case/addr_map/map_test.v (x_main_dummy_top0.hrdata) keep working.
 *
 * Bus protocol
 *   Standard AHB slave with the address phase registered. hready is tied
 *   high, so every transfer takes two cycles: the address/control phase
 *   captures haddr/hwrite/hsize, and the following data phase samples
 *   hwdata (writes) or drives hrdata (reads). This is required because
 *   the E902 core pipelines consecutive transfers, which means haddr has
 *   already moved to the next transfer while hwdata still belongs to the
 *   current one.
 *
 * Datapath
 *   8 vector registers V0..V7, each 128 bit = 4 lanes x 32 bit.
 *   One "start" trigger executes one opcode on all 4 lanes in parallel.
 *   busy is raised in the cycle the CTRL write retires, results land at
 *   the end of the next cycle and done is set one cycle later.
 *
 * Register map (offset from 0x4001_0000, word aligned only)
 *   0x000 - 0x07F  V0..V7   : 8 registers x 4 lanes, 16 bytes per register
 *                             lane index = offset[3:2], register = offset[6:4]
 *   0x080          SCLR     : scalar source, broadcast when CTRL.scalar_en=1
 *   0x084          CTRL     : [0] start (self clearing)
 *                             [4:1] op, [7:5] vd, [10:8] va, [13:11] vb
 *                             [14]  scalar_en
 *   0x088          STATUS   : [0] busy, [1] done (write 1 to clear)
 *                             [31:24] completed op counter
 *   0x08C          MASK     : [3:0] per lane write enable
 *   0x090          LANES    : read-only, number of lanes minus one (=3)
 *   0x0FC          ID       : read-only, 0x5650_5531 ('VPU1')
 *
 * Opcodes
 *   0 VADD   Vd = Va + Vb          7 VMIN   Vd = min_s(Va,Vb)
 *   1 VSUB   Vd = Va - Vb          8 VMAX   Vd = max_s(Va,Vb)
 *   2 VAND   Vd = Va & Vb          9 VABS   Vd = |Va|
 *   3 VOR    Vd = Va | Vb         10 VNEG   Vd = -Va
 *   4 VXOR   Vd = Va ^ Vb         11 VSHL   Vd = Va << Vb[4:0]
 *   5 VMUL   Vd = low32(Va*Vb)    12 VSHR   Vd = Va >> Vb[4:0]
 *   6 VMAC   Vd = Vd + Va*Vb      13 VCOPY  Vd = Va
 *
 * Only 32-bit aligned word transfers are supported; any other hsize or a
 * misaligned address is answered with an AHB ERROR response.
 */

module vpu_top(
  haddr,
  hclk,
  hprot,
  hrdata,
  hready,
  hresp,
  hrst_b,
  hsel,
  hsize,
  htrans,
  hwdata,
  hwrite,
  intr
);

input   [31:0]  haddr;
input           hclk;
input   [3 :0]  hprot;
input           hrst_b;
input           hsel;
input   [2 :0]  hsize;
input   [1 :0]  htrans;
input   [31:0]  hwdata;
input           hwrite;
output  [31:0]  hrdata;
output          hready;
output  [1 :0]  hresp;
output          intr;

/* ------------------------------------------------------------------ */
/* local parameters                                                    */
/* ------------------------------------------------------------------ */
localparam [21:0] BASE_HI   = 22'h100040;   /* 0x4001_0000 >> 10          */
localparam [3 :0] OP_VADD   = 4'd0;
localparam [3 :0] OP_VSUB   = 4'd1;
localparam [3 :0] OP_VAND   = 4'd2;
localparam [3 :0] OP_VOR    = 4'd3;
localparam [3 :0] OP_VXOR   = 4'd4;
localparam [3 :0] OP_VMUL   = 4'd5;
localparam [3 :0] OP_VMAC   = 4'd6;
localparam [3 :0] OP_VMIN   = 4'd7;
localparam [3 :0] OP_VMAX   = 4'd8;
localparam [3 :0] OP_VABS   = 4'd9;
localparam [3 :0] OP_VNEG   = 4'd10;
localparam [3 :0] OP_VSHL   = 4'd11;
localparam [3 :0] OP_VSHR   = 4'd12;
localparam [3 :0] OP_VCOPY  = 4'd13;

/* ------------------------------------------------------------------ */
/* address phase capture                                              */
/*                                                                    */
/* AHB pipelines address and data: while the data phase of transfer N */
/* is running, haddr already points at transfer N+1. Everything that  */
/* belongs to the transfer (including hwdata) must therefore be       */
/* qualified with the address captured one cycle earlier.             */
/* ------------------------------------------------------------------ */
reg         a_valid;        /* current cycle is a data phase        */
reg  [31:0] a_addr;
reg         a_write;
reg  [2 :0] a_size;

wire        addr_phase = hsel & htrans[1];

always @(posedge hclk or negedge hrst_b)
begin
  if (!hrst_b)
  begin
    a_valid <= 1'b0;
    a_addr  <= 32'b0;
    a_write <= 1'b0;
    a_size  <= 3'b0;
  end
  else
  begin
    a_valid <= addr_phase;
    if (addr_phase)
    begin
      a_addr  <= haddr;
      a_write <= hwrite;
      a_size  <= hsize;
    end
  end
end

/* ------------------------------------------------------------------ */
/* bus side decode, in terms of the latched address                    */
/* ------------------------------------------------------------------ */
wire [9 :0] off       = a_addr[9:0];
wire        addr_ok   = (a_addr[31:10] == BASE_HI);
wire        size_ok   = (a_size == 3'b010);        /* word only        */
wire        align_ok  = (a_addr[1:0] == 2'b00);
wire        access_ok = addr_ok & size_ok & align_ok;
wire        wr_en     = a_valid & a_write & access_ok;

wire        ctrl_wr   = wr_en & (off == 10'h084);
wire        stat_wr   = wr_en & (off == 10'h088);
wire        sclr_wr   = wr_en & (off == 10'h080);
wire        mask_wr   = wr_en & (off == 10'h08c);
wire        vreg_wr   = wr_en & (off <= 10'h07f);

/* ------------------------------------------------------------------ */
/* architectural state                                                 */
/* ------------------------------------------------------------------ */
reg  [127:0] vreg   [0:7];      /* vector register file               */
reg  [31:0]  sclr_r;            /* scalar source                      */
reg  [3 :0]  op_r;              /* latched opcode                     */
reg  [2 :0]  vd_r;              /* latched destination index          */
reg  [2 :0]  va_r;              /* latched source A index             */
reg  [2 :0]  vb_r;              /* latched source B index             */
reg          scalar_en_r;       /* broadcast SCLR instead of Vb       */
reg  [3 :0]  mask_r;            /* per lane write enable              */
reg          busy_r;
reg          done_r;
reg  [7 :0]  ops_cnt;           /* completed operations, wraps        */

integer      j;

/* ------------------------------------------------------------------ */
/* per lane ALU                                                        */
/* ------------------------------------------------------------------ */
function [31:0] vpu_alu;
  input [3 :0]  op;
  input [31:0]  a;
  input [31:0]  b;
  input [31:0]  d;
  reg   [63:0]  prod;
  begin
    prod = a * b;
    case (op)
      OP_VADD : vpu_alu = a + b;
      OP_VSUB : vpu_alu = a - b;
      OP_VAND : vpu_alu = a & b;
      OP_VOR  : vpu_alu = a | b;
      OP_VXOR : vpu_alu = a ^ b;
      OP_VMUL : vpu_alu = prod[31:0];
      OP_VMAC : vpu_alu = d + prod[31:0];
      OP_VMIN : vpu_alu = ($signed(a) < $signed(b)) ? a : b;
      OP_VMAX : vpu_alu = ($signed(a) > $signed(b)) ? a : b;
      /* abs(INT32_MIN) saturates back to INT32_MIN, same as C */
      OP_VABS : vpu_alu = ($signed(a) < 0) ? (32'h0 - a) : a;
      OP_VNEG : vpu_alu = 32'h0 - a;
      OP_VSHL : vpu_alu = a << b[4:0];
      OP_VSHR : vpu_alu = a >> b[4:0];
      OP_VCOPY: vpu_alu = a;
      default : vpu_alu = a;
    endcase
  end
endfunction

wire [31:0]  res_lane [0:3];
wire [127:0] vd_new;

genvar gi;
generate
  for (gi = 0; gi < 4; gi = gi + 1) begin : gen_lane
    /* operand B is either the matching lane of Vb or the broadcast scalar */
    wire [31:0] b_operand = scalar_en_r ? sclr_r : vreg[vb_r][gi*32 +: 32];
    assign res_lane[gi] = vpu_alu(op_r,
                                  vreg[va_r][gi*32 +: 32],
                                  b_operand,
                                  vreg[vd_r][gi*32 +: 32]);
    /* lanes disabled by MASK keep their previous value */
    assign vd_new[gi*32 +: 32] = mask_r[gi] ? res_lane[gi]
                                            : vreg[vd_r][gi*32 +: 32];
  end
endgenerate

/* ------------------------------------------------------------------ */
/* sequential: register file, control, status                          */
/* ------------------------------------------------------------------ */
always @(posedge hclk or negedge hrst_b)
begin
  if (!hrst_b)
  begin
    for (j = 0; j < 8; j = j + 1)
      vreg[j] <= 128'b0;
    sclr_r      <= 32'b0;
    op_r        <= 4'b0;
    vd_r        <= 3'b0;
    va_r        <= 3'b0;
    vb_r        <= 3'b0;
    scalar_en_r <= 1'b0;
    mask_r      <= 4'hf;
    busy_r      <= 1'b0;
    done_r      <= 1'b0;
    ops_cnt     <= 8'b0;
  end
  else if (busy_r)
  begin
    /* second cycle of the operation: commit result, retire */
    vreg[vd_r] <= vd_new;
    busy_r     <= 1'b0;
    done_r     <= 1'b1;
    ops_cnt    <= ops_cnt + 8'b1;
  end
  else
  begin
    if (vreg_wr)
    begin
      /* only the addressed lane is written, the other three keep their value */
      case (off[3:2])
        2'd0 : vreg[off[6:4]][ 31: 0] <= hwdata;
        2'd1 : vreg[off[6:4]][ 63:32] <= hwdata;
        2'd2 : vreg[off[6:4]][ 95:64] <= hwdata;
        2'd3 : vreg[off[6:4]][127:96] <= hwdata;
      endcase
    end
    if (sclr_wr)
      sclr_r <= hwdata;
    if (mask_wr)
      mask_r <= hwdata[3:0];
    if (ctrl_wr)
    begin
      op_r        <= hwdata[4:1];
      vd_r        <= hwdata[7:5];
      va_r        <= hwdata[10:8];
      vb_r        <= hwdata[13:11];
      scalar_en_r <= hwdata[14];
      if (hwdata[0])
        busy_r <= 1'b1;
    end
    if (stat_wr && hwdata[1])
      done_r <= 1'b0;
  end
end

/* ------------------------------------------------------------------ */
/* read mux, driven in the data phase from the latched address         */
/* ------------------------------------------------------------------ */
reg [31:0] rd_mux;

always @(*)
begin
  if (off <= 10'h07f)
    rd_mux = vreg[off[6:4]][ {off[3:2], 5'b0} +: 32 ];
  else
  begin
    case (off)
      10'h080 : rd_mux = sclr_r;
      10'h084 : rd_mux = { 17'b0, scalar_en_r, vb_r, va_r, vd_r, op_r, 1'b0 };
      10'h088 : rd_mux = { ops_cnt, 22'b0, done_r, busy_r };
      10'h08c : rd_mux = { 28'b0, mask_r };
      10'h090 : rd_mux = 32'd3;                    /* 4 lanes - 1 */
      10'h0fc : rd_mux = 32'h5650_5531;            /* 'VPU1'      */
      default : rd_mux = 32'h0;
    endcase
  end
end

assign hrdata = rd_mux;
assign hready = 1'b1;
assign hresp  = (a_valid & !access_ok) ? 2'b01 : 2'b00;

/* done is a level: it stays asserted until software clears STATUS[1].
   The SoC currently leaves main_dummy0_intr unconnected, so software polls
   STATUS instead, but the irq line is kept for a future VIC hookup. */
assign intr   = done_r;

endmodule
