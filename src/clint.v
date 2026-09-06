// -----------------------------------------------------------------------------
// clint.v - minimal single-hart RISC-V CLINT-compatible timer/software IRQ block
// Base address in the SoC: 0x0200_0000
//   +0x0000  MSIP hart 0
//   +0x4000  MTIMECMP low
//   +0x4004  MTIMECMP high
//   +0xBFF8  MTIME low
//   +0xBFFC  MTIME high
// -----------------------------------------------------------------------------
module clint (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire [15:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,
    output wire        irq_software,
    output wire        irq_timer,
    output wire [63:0] mtime_value
);
    reg        msip;
    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    assign irq_software = msip;
    assign irq_timer    = (mtime >= mtimecmp);
    assign mtime_value  = mtime;

    function [31:0] merge_bytes;
        input [31:0] oldv;
        input [31:0] newv;
        input [3:0]  strb;
        begin
            merge_bytes = oldv;
            if (strb[0]) merge_bytes[7:0]   = newv[7:0];
            if (strb[1]) merge_bytes[15:8]  = newv[15:8];
            if (strb[2]) merge_bytes[23:16] = newv[23:16];
            if (strb[3]) merge_bytes[31:24] = newv[31:24];
        end
    endfunction

    always @(*) begin
        case (bus_addr)
            16'h0000: bus_rdata = {31'd0,msip};
            16'h4000: bus_rdata = mtimecmp[31:0];
            16'h4004: bus_rdata = mtimecmp[63:32];
            16'hBFF8: bus_rdata = mtime[31:0];
            16'hBFFC: bus_rdata = mtime[63:32];
            default:  bus_rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msip     <= 1'b0;
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            mtime <= mtime + 64'd1;
            if (bus_valid && |bus_wstrb) begin
                case (bus_addr)
                    16'h0000: if (bus_wstrb[0]) msip <= bus_wdata[0];
                    16'h4000: mtimecmp[31:0]  <= merge_bytes(mtimecmp[31:0], bus_wdata, bus_wstrb);
                    16'h4004: mtimecmp[63:32] <= merge_bytes(mtimecmp[63:32],bus_wdata, bus_wstrb);
                    16'hBFF8: mtime[31:0]     <= merge_bytes(mtime[31:0], bus_wdata, bus_wstrb);
                    16'hBFFC: mtime[63:32]    <= merge_bytes(mtime[63:32],bus_wdata, bus_wstrb);
                    default: ;
                endcase
            end
        end
    end
endmodule
