// GPIO, edge interrupts, and physical pin multiplexing.
module gpio_pinmux (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,

    input  wire [7:0]  ui_in,
    input  wire [7:0]  uio_in,
    output reg  [7:0]  uo_out,
    output reg  [7:0]  uio_out,
    output reg  [7:0]  uio_oe,

    // Dedicated flash and PSRAM signals.
    input  wire        flash_cs_n,
    input  wire        flash_mosi,
    input  wire        flash_sck,
    input  wire        ram_cs_n,
    input  wire        ram_sck,
    input  wire [3:0]  ram_dq_o,
    input  wire [3:0]  ram_dq_oe,

    // Peripheral alternate functions.
    input  wire        uart_tx,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    input  wire        spi_sck,
    input  wire [4:0]  pwm_out,
    input  wire        i2c_scl_drive_low,
    input  wire        i2c_sda_drive_low,

    output wire        gpio_irq
);
    reg [7:0]  gpio_uo;
    reg [7:0]  gpio_uio_out;
    reg [7:0]  gpio_uio_oe;
    reg [9:0]  pinmux_uo;
    reg [1:0]  pinmux_uio;
    reg [15:0] irq_rise;
    reg [15:0] irq_fall;
    reg [15:0] irq_pending;
    reg [15:0] last_inputs;

    wire [15:0] all_inputs = {uio_in,ui_in};
    wire [15:0] rising_edges  = ~last_inputs & all_inputs;
    wire [15:0] falling_edges = last_inputs & ~all_inputs;
    wire [15:0] new_edges = (rising_edges & irq_rise) | (falling_edges & irq_fall);

    assign gpio_irq = |irq_pending;

    always @(*) begin
        uo_out  = 8'd0;
        uio_out = 8'd0;
        uio_oe  = 8'd0;

        // Dedicated external boot flash pins.
        uo_out[0] = flash_cs_n;
        uo_out[1] = flash_mosi;
        uo_out[2] = flash_sck;

        case (pinmux_uo[1:0])
            2'd1: uo_out[3] = uart_tx;
            2'd2: uo_out[3] = pwm_out[0];
            default: uo_out[3] = gpio_uo[3];
        endcase
        case (pinmux_uo[3:2])
            2'd1: uo_out[4] = spi_cs_n;
            2'd2: uo_out[4] = pwm_out[1];
            default: uo_out[4] = gpio_uo[4];
        endcase
        case (pinmux_uo[5:4])
            2'd1: uo_out[5] = spi_mosi;
            2'd2: uo_out[5] = pwm_out[2];
            default: uo_out[5] = gpio_uo[5];
        endcase
        case (pinmux_uo[7:6])
            2'd1: uo_out[6] = spi_sck;
            2'd2: uo_out[6] = pwm_out[3];
            default: uo_out[6] = gpio_uo[6];
        endcase
        case (pinmux_uo[9:8])
            2'd1: uo_out[7] = pwm_out[4];
            default: uo_out[7] = gpio_uo[7];
        endcase

        // Dedicated external PSRAM pins.
        uio_out[0] = ram_cs_n; uio_oe[0] = 1'b1;
        uio_out[1] = ram_sck;  uio_oe[1] = 1'b1;
        uio_out[5:2] = ram_dq_o;
        uio_oe[5:2]  = ram_dq_oe;

        // GPIO/I2C pins. I2C is open-drain: output value is always zero and OE
        // is asserted only when the controller needs to pull the line low.
        if (pinmux_uio[0]) begin
            uio_out[6] = 1'b0;
            uio_oe[6]  = i2c_scl_drive_low;
        end else begin
            uio_out[6] = gpio_uio_out[6];
            uio_oe[6]  = gpio_uio_oe[6];
        end
        if (pinmux_uio[1]) begin
            uio_out[7] = 1'b0;
            uio_oe[7]  = i2c_sda_drive_low;
        end else begin
            uio_out[7] = gpio_uio_out[7];
            uio_oe[7]  = gpio_uio_oe[7];
        end
    end

    always @(*) begin
        case (bus_addr)
            8'h00: bus_rdata = {24'd0,ui_in};
            8'h04: bus_rdata = {24'd0,gpio_uo};
            8'h08: bus_rdata = {24'd0,uio_in};
            8'h0C: bus_rdata = {24'd0,gpio_uio_out};
            8'h10: bus_rdata = {24'd0,gpio_uio_oe};
            8'h14: bus_rdata = {22'd0,pinmux_uo};
            8'h18: bus_rdata = {30'd0,pinmux_uio};
            8'h20: bus_rdata = {16'd0,irq_rise};
            8'h24: bus_rdata = {16'd0,irq_fall};
            8'h28: bus_rdata = {16'd0,irq_pending};
            default: bus_rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_uo       <= 8'd0;
            gpio_uio_out  <= 8'd0;
            gpio_uio_oe   <= 8'd0;
            // UART TX is selected on uo3 at reset for early console output.
            pinmux_uo     <= 10'b00_00_00_00_01;
            pinmux_uio    <= 2'b00;
            irq_rise      <= 16'd0;
            irq_fall      <= 16'd0;
            irq_pending   <= 16'd0;
            last_inputs   <= 16'd0;
        end else begin
            last_inputs <= all_inputs;
            irq_pending <= irq_pending | new_edges;

            if (bus_valid && |bus_wstrb) begin
                case (bus_addr)
                    8'h04: begin
                        if (bus_wstrb[0]) gpio_uo <= bus_wdata[7:0];
                    end
                    8'h0C: begin
                        if (bus_wstrb[0]) gpio_uio_out <= bus_wdata[7:0];
                    end
                    8'h10: begin
                        if (bus_wstrb[0]) gpio_uio_oe <= bus_wdata[7:0];
                    end
                    8'h14: begin
                        if (bus_wstrb[0]) pinmux_uo[7:0] <= bus_wdata[7:0];
                        if (bus_wstrb[1]) pinmux_uo[9:8] <= bus_wdata[9:8];
                    end
                    8'h18: if (bus_wstrb[0]) pinmux_uio <= bus_wdata[1:0];
                    8'h20: begin
                        if (bus_wstrb[0]) irq_rise[7:0]  <= bus_wdata[7:0];
                        if (bus_wstrb[1]) irq_rise[15:8] <= bus_wdata[15:8];
                    end
                    8'h24: begin
                        if (bus_wstrb[0]) irq_fall[7:0]  <= bus_wdata[7:0];
                        if (bus_wstrb[1]) irq_fall[15:8] <= bus_wdata[15:8];
                    end
                    8'h28: begin
                        if (bus_wstrb[0]) irq_pending[7:0]  <= (irq_pending[7:0]  | new_edges[7:0])  & ~bus_wdata[7:0];
                        if (bus_wstrb[1]) irq_pending[15:8] <= (irq_pending[15:8] | new_edges[15:8]) & ~bus_wdata[15:8];
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
