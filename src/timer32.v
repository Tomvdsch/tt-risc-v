// -----------------------------------------------------------------------------
// timer32.v - 32-bit general-purpose down counter.
// Register offsets: 0x00 LOAD, 0x04 VALUE, 0x08 CTRL, 0x0C STATUS
// CTRL: bit0 enable, bit1 periodic, bit2 IRQ enable
// STATUS: bit0 pending; write bit0=1 to clear.
// -----------------------------------------------------------------------------
module timer32 (
    input wire clk, input wire rst_n,
    input wire bus_valid, input wire [7:0] bus_addr,
    input wire [31:0] bus_wdata, input wire [3:0] bus_wstrb,
    output reg [31:0] bus_rdata, output wire irq
);
    reg [31:0] load_value;
    reg [31:0] counter;
    reg [2:0] ctrl;
    reg pending;

    assign irq = ctrl[2] & pending;

    always @(*) begin
        case (bus_addr)
            8'h00: bus_rdata = load_value;
            8'h04: bus_rdata = counter;
            8'h08: bus_rdata = {29'd0,ctrl};
            8'h0C: bus_rdata = {31'd0,pending};
            default: bus_rdata = 32'd0;
        endcase
    end

    function [31:0] merge_bytes;
        input [31:0] oldv, newv; input [3:0] strb;
        begin
            merge_bytes=oldv;
            if(strb[0]) merge_bytes[7:0]=newv[7:0];
            if(strb[1]) merge_bytes[15:8]=newv[15:8];
            if(strb[2]) merge_bytes[23:16]=newv[23:16];
            if(strb[3]) merge_bytes[31:24]=newv[31:24];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            load_value<=32'd0; counter<=32'd0; ctrl<=3'd0; pending<=1'b0;
        end else begin
            if(ctrl[0]) begin
                if(counter != 0)
                    counter <= counter - 32'd1;
                else begin
                    pending <= 1'b1;
                    if(ctrl[1]) counter <= load_value;
                    else ctrl[0] <= 1'b0;
                end
            end
            if(bus_valid && |bus_wstrb) begin
                case(bus_addr)
                    8'h00: load_value <= merge_bytes(load_value,bus_wdata,bus_wstrb);
                    8'h04: counter    <= merge_bytes(counter,bus_wdata,bus_wstrb);
                    8'h08: if(bus_wstrb[0]) begin
                        ctrl <= bus_wdata[2:0];
                        if(bus_wdata[0] && !ctrl[0]) counter <= load_value;
                    end
                    8'h0C: if(bus_wstrb[0] && bus_wdata[0]) pending <= 1'b0;
                    default: ;
                endcase
            end
        end
    end
endmodule
