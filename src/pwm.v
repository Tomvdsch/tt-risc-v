// -----------------------------------------------------------------------------
// pwm.v - five PWM channels sharing one 16-bit period counter.
// Sharing the counter saves significant area. All channels therefore use the
// same period but can have independent duty cycles.
// Base: 0x1000_5000
//   0x00 PERIOD
//   0x04 CTRL bit0 global enable, bits[5:1] channel enables
//   0x10..0x20 DUTY0..DUTY4
// -----------------------------------------------------------------------------
module pwm (
    input wire clk, input wire rst_n,
    input wire bus_valid, input wire [7:0] bus_addr,
    input wire [31:0] bus_wdata, input wire [3:0] bus_wstrb,
    output reg [31:0] bus_rdata,
    output wire [4:0] pwm_out
);
    reg [15:0] period;
    reg [15:0] counter;
    reg [5:0] ctrl;
    reg [15:0] duty0,duty1,duty2,duty3,duty4;

    assign pwm_out[0] = ctrl[0] & ctrl[1] & (counter < duty0);
    assign pwm_out[1] = ctrl[0] & ctrl[2] & (counter < duty1);
    assign pwm_out[2] = ctrl[0] & ctrl[3] & (counter < duty2);
    assign pwm_out[3] = ctrl[0] & ctrl[4] & (counter < duty3);
    assign pwm_out[4] = ctrl[0] & ctrl[5] & (counter < duty4);

    always @(*) begin
        case(bus_addr)
            8'h00: bus_rdata={16'd0,period};
            8'h04: bus_rdata={26'd0,ctrl};
            8'h08: bus_rdata={16'd0,counter};
            8'h10: bus_rdata={16'd0,duty0};
            8'h14: bus_rdata={16'd0,duty1};
            8'h18: bus_rdata={16'd0,duty2};
            8'h1C: bus_rdata={16'd0,duty3};
            8'h20: bus_rdata={16'd0,duty4};
            default: bus_rdata=32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            period<=16'hFFFF; counter<=16'd0; ctrl<=6'd0;
            duty0<=0; duty1<=0; duty2<=0; duty3<=0; duty4<=0;
        end else begin
            if(ctrl[0]) begin
                if(counter >= period) counter<=16'd0;
                else counter<=counter+16'd1;
            end else counter<=16'd0;
            if(bus_valid && |bus_wstrb) begin
                case(bus_addr)
                    8'h00: begin
                        if(bus_wstrb[0]) period[7:0]<=bus_wdata[7:0];
                        if(bus_wstrb[1]) period[15:8]<=bus_wdata[15:8];
                    end
                    8'h04: if(bus_wstrb[0]) ctrl<=bus_wdata[5:0];
                    8'h10: begin if(bus_wstrb[0]) duty0[7:0]<=bus_wdata[7:0]; if(bus_wstrb[1]) duty0[15:8]<=bus_wdata[15:8]; end
                    8'h14: begin if(bus_wstrb[0]) duty1[7:0]<=bus_wdata[7:0]; if(bus_wstrb[1]) duty1[15:8]<=bus_wdata[15:8]; end
                    8'h18: begin if(bus_wstrb[0]) duty2[7:0]<=bus_wdata[7:0]; if(bus_wstrb[1]) duty2[15:8]<=bus_wdata[15:8]; end
                    8'h1C: begin if(bus_wstrb[0]) duty3[7:0]<=bus_wdata[7:0]; if(bus_wstrb[1]) duty3[15:8]<=bus_wdata[15:8]; end
                    8'h20: begin if(bus_wstrb[0]) duty4[7:0]<=bus_wdata[7:0]; if(bus_wstrb[1]) duty4[15:8]<=bus_wdata[15:8]; end
                    default: ;
                endcase
            end
        end
    end
endmodule
