// -----------------------------------------------------------------------------
// i2c_master.v - compact command-oriented I2C master.
// Base: 0x1000_4000
//   0x00 PRESCALE  SCL half-period in system clocks (default 160 -> ~100 kHz)
//   0x04 CTRL      bit0 enable, bit1 IRQ enable
//   0x08 TXRX      W: transmit byte, R: received byte
//   0x0C CMD/STAT  write command bits:
//                  bit0 START, bit1 STOP, bit2 READ, bit3 WRITE,
//                  bit4 ACK_IN (after READ: 0=ACK, 1=NACK), bit7 clear IRQ
//                  read status bits:
//                  bit0 TIP/busy, bit1 RXACK (1=NACK), bit2 IRQ pending
//
// SCL/SDA outputs are open-drain drive-low controls. External pull-ups are
// required, as on a normal I2C bus.
// -----------------------------------------------------------------------------
module i2c_master #(
    parameter DEFAULT_PRESCALE = 160
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,
    input  wire        scl_in,
    input  wire        sda_in,
    output reg         scl_drive_low,
    output reg         sda_drive_low,
    output wire        irq
);
    localparam ST_IDLE       = 5'd0;
    localparam ST_START_A    = 5'd1;
    localparam ST_START_B    = 5'd2;
    localparam ST_W_SETUP    = 5'd3;
    localparam ST_W_HIGH     = 5'd4;
    localparam ST_W_LOW      = 5'd5;
    localparam ST_ACK_SETUP  = 5'd6;
    localparam ST_ACK_HIGH   = 5'd7;
    localparam ST_ACK_LOW    = 5'd8;
    localparam ST_R_SETUP    = 5'd9;
    localparam ST_R_HIGH     = 5'd10;
    localparam ST_R_LOW      = 5'd11;
    localparam ST_RACK_SETUP = 5'd12;
    localparam ST_RACK_HIGH  = 5'd13;
    localparam ST_RACK_LOW   = 5'd14;
    localparam ST_STOP_A     = 5'd15;
    localparam ST_STOP_B     = 5'd16;
    localparam ST_STOP_C     = 5'd17;
    localparam ST_DONE       = 5'd18;

    reg [4:0] state;
    reg [15:0] prescale;
    reg [15:0] delay_count;
    reg [1:0] ctrl;
    reg [7:0] tx_data;
    reg [7:0] rx_data;
    reg [2:0] bit_index;
    reg       rxack;
    reg       irq_pending;
    reg       cmd_stop;
    reg       cmd_read;
    reg       cmd_write;
    reg       cmd_ack_in;

    wire enabled = ctrl[0];
    wire busy = (state != ST_IDLE);
    assign irq = ctrl[1] & irq_pending;

    always @(*) begin
        case (bus_addr)
            8'h00: bus_rdata = {16'd0,prescale};
            8'h04: bus_rdata = {30'd0,ctrl};
            8'h08: bus_rdata = {24'd0,rx_data};
            8'h0C: bus_rdata = {29'd0,irq_pending,rxack,busy};
            default: bus_rdata = 32'd0;
        endcase
    end

    // Reload the timing counter. A value of zero is legal and produces the
    // fastest possible bit engine for simulation/bring-up.
    task reload_delay;
        begin
            delay_count <= (prescale > 0) ? prescale - 16'd1 : 16'd0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            prescale       <= DEFAULT_PRESCALE;
            delay_count    <= 16'd0;
            ctrl            <= 2'd0;
            tx_data         <= 8'd0;
            rx_data         <= 8'd0;
            bit_index       <= 3'd7;
            rxack           <= 1'b0;
            irq_pending     <= 1'b0;
            cmd_stop        <= 1'b0;
            cmd_read        <= 1'b0;
            cmd_write       <= 1'b0;
            cmd_ack_in      <= 1'b1;
            scl_drive_low   <= 1'b0;
            sda_drive_low   <= 1'b0;
        end else begin
            // MMIO register writes.
            if (bus_valid && |bus_wstrb) begin
                case (bus_addr)
                    8'h00: begin
                        if (bus_wstrb[0]) prescale[7:0]  <= bus_wdata[7:0];
                        if (bus_wstrb[1]) prescale[15:8] <= bus_wdata[15:8];
                    end
                    8'h04: if (bus_wstrb[0]) ctrl <= bus_wdata[1:0];
                    8'h08: if (bus_wstrb[0]) tx_data <= bus_wdata[7:0];
                    8'h0C: if (bus_wstrb[0]) begin
                        if (bus_wdata[7]) irq_pending <= 1'b0;
                        if (enabled && state == ST_IDLE && (bus_wdata[2] || bus_wdata[3])) begin
                            cmd_stop   <= bus_wdata[1];
                            cmd_read   <= bus_wdata[2];
                            cmd_write  <= bus_wdata[3];
                            cmd_ack_in <= bus_wdata[4];
                            bit_index  <= 3'd7;
                            rxack      <= 1'b0;
                            irq_pending<= 1'b0;
                            if (bus_wdata[0]) begin
                                // START: both lines released, then SDA falls
                                // while SCL is high.
                                scl_drive_low <= 1'b0;
                                sda_drive_low <= 1'b0;
                                reload_delay;
                                state <= ST_START_A;
                            end else if (bus_wdata[3]) begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= ~tx_data[7];
                                reload_delay;
                                state <= ST_W_SETUP;
                            end else begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                reload_delay;
                                state <= ST_R_SETUP;
                            end
                        end
                    end
                    default: ;
                endcase
            end

            case (state)
                ST_IDLE: begin
                    // Do not force SDA/SCL here: after a completed transaction
                    // they are normally released by STOP. A transaction without
                    // STOP intentionally leaves SCL low for a repeated command.
                end

                ST_START_A: begin
                    // Honor clock stretching before generating START.
                    if (!scl_in) begin
                        delay_count <= delay_count;
                    end else if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        sda_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_START_B;
                    end
                end

                ST_START_B: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b1;
                        reload_delay;
                        if (cmd_write) begin
                            sda_drive_low <= ~tx_data[7];
                            state <= ST_W_SETUP;
                        end else begin
                            sda_drive_low <= 1'b0;
                            state <= ST_R_SETUP;
                        end
                    end
                end

                ST_W_SETUP: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b0;
                        reload_delay;
                        state <= ST_W_HIGH;
                    end
                end

                ST_W_HIGH: begin
                    if (!scl_in) begin
                        delay_count <= delay_count;
                    end else if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_W_LOW;
                    end
                end

                ST_W_LOW: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else if (bit_index == 0) begin
                        sda_drive_low <= 1'b0; // release for ACK
                        reload_delay;
                        state <= ST_ACK_SETUP;
                    end else begin
                        bit_index <= bit_index - 3'd1;
                        sda_drive_low <= ~tx_data[bit_index - 3'd1];
                        reload_delay;
                        state <= ST_W_SETUP;
                    end
                end

                ST_ACK_SETUP: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b0;
                        reload_delay;
                        state <= ST_ACK_HIGH;
                    end
                end

                ST_ACK_HIGH: begin
                    if (!scl_in) begin
                        delay_count <= delay_count;
                    end else if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        rxack <= sda_in;
                        scl_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_ACK_LOW;
                    end
                end

                ST_ACK_LOW: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else if (cmd_stop) begin
                        sda_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_STOP_A;
                    end else
                        state <= ST_DONE;
                end

                ST_R_SETUP: begin
                    sda_drive_low <= 1'b0;
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b0;
                        reload_delay;
                        state <= ST_R_HIGH;
                    end
                end

                ST_R_HIGH: begin
                    if (!scl_in) begin
                        delay_count <= delay_count;
                    end else if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        rx_data[bit_index] <= sda_in;
                        scl_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_R_LOW;
                    end
                end

                ST_R_LOW: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else if (bit_index == 0) begin
                        sda_drive_low <= ~cmd_ack_in; // ACK=drive low, NACK=release
                        reload_delay;
                        state <= ST_RACK_SETUP;
                    end else begin
                        bit_index <= bit_index - 3'd1;
                        reload_delay;
                        state <= ST_R_SETUP;
                    end
                end

                ST_RACK_SETUP: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b0;
                        reload_delay;
                        state <= ST_RACK_HIGH;
                    end
                end

                ST_RACK_HIGH: begin
                    if (!scl_in) begin
                        delay_count <= delay_count;
                    end else if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_RACK_LOW;
                    end
                end

                ST_RACK_LOW: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else if (cmd_stop) begin
                        sda_drive_low <= 1'b1;
                        reload_delay;
                        state <= ST_STOP_A;
                    end else begin
                        sda_drive_low <= 1'b0;
                        state <= ST_DONE;
                    end
                end

                ST_STOP_A: begin
                    // SDA low, SCL low. Release SCL first.
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        scl_drive_low <= 1'b0;
                        reload_delay;
                        state <= ST_STOP_B;
                    end
                end

                ST_STOP_B: begin
                    if (!scl_in) begin
                        delay_count <= delay_count;
                    end else if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else begin
                        sda_drive_low <= 1'b0;
                        reload_delay;
                        state <= ST_STOP_C;
                    end
                end

                ST_STOP_C: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 16'd1;
                    else
                        state <= ST_DONE;
                end

                ST_DONE: begin
                    irq_pending <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
