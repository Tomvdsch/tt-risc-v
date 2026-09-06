// -----------------------------------------------------------------------------
// watchdog.v - 32-bit watchdog down counter.
// Base: 0x1000_7000
//   0x00 RELOAD
//   0x04 VALUE
//   0x08 CTRL bit0 enable, bit1 IRQ enable, bit2 reset-pulse enable
//   0x0C FEED write 0x51F15EED to reload and clear expired
//   0x10 STATUS bit0 expired
// -----------------------------------------------------------------------------
module watchdog (
    input wire clk, input wire rst_n,
    input wire bus_valid, input wire [7:0] bus_addr,
    input wire [31:0] bus_wdata, input wire [3:0] bus_wstrb,
    output reg [31:0] bus_rdata,
    output wire irq, output reg reset_pulse
);
    reg [31:0] reload_value, counter;
    reg [2:0] ctrl;
    reg expired;
    assign irq = ctrl[1] & expired;

    always @(*) begin
        case(bus_addr)
            8'h00: bus_rdata=reload_value;
            8'h04: bus_rdata=counter;
            8'h08: bus_rdata={29'd0,ctrl};
            8'h10: bus_rdata={31'd0,expired};
            default: bus_rdata=32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            reload_value<=32'd0; counter<=32'd0; ctrl<=3'd0;
            expired<=1'b0; reset_pulse<=1'b0;
        end else begin
            reset_pulse<=1'b0;
            if(ctrl[0] && !expired) begin
                if(counter!=0) counter<=counter-32'd1;
                else begin
                    expired<=1'b1;
                    ctrl[0]<=1'b0;
                    if(ctrl[2]) reset_pulse<=1'b1;
                end
            end
            if(bus_valid && |bus_wstrb) begin
                case(bus_addr)
                    8'h00: reload_value<=bus_wdata;
                    8'h04: counter<=bus_wdata;
                    8'h08: if(bus_wstrb[0]) begin
                        ctrl<=bus_wdata[2:0];
                        if(bus_wdata[0] && !ctrl[0]) begin counter<=reload_value; expired<=1'b0; end
                    end
                    8'h0C: if(bus_wdata==32'h51F1_5EED) begin counter<=reload_value; expired<=1'b0; end
                    default: ;
                endcase
            end
        end
    end
endmodule
