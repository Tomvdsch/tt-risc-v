// APS6404L controller: serial 38h/EBh command, quad address and data.
// Read transactions insert six dummy clocks. SCK idles high.
module qspi_psram #(
    parameter integer POWERUP_WAIT_CYCLES = 6400,
    parameter integer RESET_WAIT_CYCLES   = 160000,
    parameter integer INTEROP_WAIT_CYCLES = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid,
    input  wire        req_write,
    input  wire [22:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    input  wire [3:0]  req_words,
    output wire        req_ready,
    output reg         req_done,
    output reg         rd_valid,
    output reg  [31:0] rd_data,
    output reg         init_done,

    output reg         ram_cs_n,
    output reg         ram_sck,
    output reg  [3:0]  ram_dq_o,
    output reg  [3:0]  ram_dq_oe,
    input  wire [3:0]  ram_dq_i
);

    localparam ST_POWER       = 5'd0;
    localparam ST_QEXIT       = 5'd1;
    localparam ST_QEXIT_HOLD  = 5'd2;
    localparam ST_GAP66       = 5'd3;
    localparam ST_SERIAL      = 5'd4;
    localparam ST_SERIAL_HOLD = 5'd5;
    localparam ST_GAP99       = 5'd6;
    localparam ST_RESET_WAIT  = 5'd7;
    localparam ST_READY       = 5'd8;
    localparam ST_CMD         = 5'd9;
    localparam ST_ADDR        = 5'd10;
    localparam ST_DUMMY       = 5'd11;
    localparam ST_READ        = 5'd12;
    localparam ST_WRITE       = 5'd13;
    localparam ST_FINISH      = 5'd14;
    localparam ST_INTEROP     = 5'd15;

    reg [4:0] state;
    reg [17:0] wait_count;

    reg [7:0] serial_shift;
    reg [3:0] serial_bits_left;
    reg [4:0] serial_next_state;

    reg [31:0] quad_shift;
    reg [3:0] quad_nibbles_left;

    reg        latched_write;
    reg [22:0] latched_addr;
    reg [3:0]  latched_words;

    reg [31:0] write_shift;
    reg [2:0]  write_bytes_left;
    reg        write_half;

    reg [6:0] read_nibbles_left;
    reg [2:0] read_nibble_index;
    reg [3:0] read_hi_nibble;

    reg [1:0] first_lane;
    reg [2:0] byte_count;
    // A request is accepted only while the controller is idle. Masters keep
    // req_valid asserted until req_ready is observed, so arbitration cannot
    // silently lose a request while another serial transaction is active.
    assign req_ready = (state == ST_READY);

    always @(*) begin
        case (req_wstrb)
            4'b0001: begin first_lane = 2'd0; byte_count = 3'd1; end
            4'b0010: begin first_lane = 2'd1; byte_count = 3'd1; end
            4'b0100: begin first_lane = 2'd2; byte_count = 3'd1; end
            4'b1000: begin first_lane = 2'd3; byte_count = 3'd1; end
            4'b0011: begin first_lane = 2'd0; byte_count = 3'd2; end
            4'b0110: begin first_lane = 2'd1; byte_count = 3'd2; end
            4'b1100: begin first_lane = 2'd2; byte_count = 3'd2; end
            4'b0111: begin first_lane = 2'd0; byte_count = 3'd3; end
            4'b1110: begin first_lane = 2'd1; byte_count = 3'd3; end
            4'b1111: begin first_lane = 2'd0; byte_count = 3'd4; end
            default: begin first_lane = 2'd0; byte_count = 3'd4; end
        endcase
    end

    task launch_serial;
        input [7:0] command;
        input [4:0] next_state;
        begin
            ram_cs_n          <= 1'b0;
            ram_sck           <= 1'b0;
            ram_dq_oe         <= 4'b0001;
            ram_dq_o          <= {3'b000,command[7]};
            serial_shift      <= command;
            serial_bits_left  <= 4'd8;
            serial_next_state <= next_state;
            state             <= ST_SERIAL;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_POWER;
            wait_count         <= POWERUP_WAIT_CYCLES[17:0];
            req_done           <= 1'b0;
            rd_valid           <= 1'b0;
            rd_data            <= 32'd0;
            init_done          <= 1'b0;
            ram_cs_n           <= 1'b1;
            ram_sck            <= 1'b1;
            ram_dq_o           <= 4'd0;
            ram_dq_oe          <= 4'd0;
            serial_shift       <= 8'd0;
            serial_bits_left   <= 4'd0;
            serial_next_state  <= ST_POWER;
            quad_shift         <= 32'd0;
            quad_nibbles_left  <= 4'd0;
            latched_write      <= 1'b0;
            latched_addr       <= 23'd0;
            latched_words      <= 4'd1;
            write_shift        <= 32'd0;
            write_bytes_left   <= 3'd0;
            write_half         <= 1'b0;
            read_nibbles_left  <= 7'd0;
            read_nibble_index  <= 3'd0;
            read_hi_nibble     <= 4'd0;
        end else begin
            req_done <= 1'b0;
            rd_valid <= 1'b0;

            case (state)
                ST_POWER: begin
                    ram_cs_n  <= 1'b1;
                    ram_sck   <= 1'b1;
                    ram_dq_oe <= 4'd0;
                    if (wait_count != 0)
                        wait_count <= wait_count - 18'd1;
                    else begin
                        // Two quad cycles transmit F5. A SPI-mode device sees
                        // only a truncated serial command and ignores it.
                        ram_cs_n          <= 1'b0;
                        ram_dq_oe         <= 4'b1111;
                        ram_sck           <= 1'b0;
                        ram_dq_o          <= 4'hF;
                        quad_shift        <= 32'hF5000000;
                        quad_nibbles_left <= 4'd2;
                        state             <= ST_QEXIT;
                    end
                end

                ST_QEXIT: begin
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                    end else begin
                        ram_sck <= 1'b0;
                        if (quad_nibbles_left == 1) begin
                            ram_cs_n  <= 1'b1;
                            ram_dq_oe <= 4'd0;
                            state     <= ST_QEXIT_HOLD;
                        end else begin
                            quad_shift        <= quad_shift << 4;
                            quad_nibbles_left <= quad_nibbles_left - 4'd1;
                            ram_dq_o          <= quad_shift[27:24];
                        end
                    end
                end

                ST_QEXIT_HOLD: begin
                    ram_cs_n   <= 1'b1;
                    ram_sck    <= 1'b1;
                    ram_dq_oe  <= 4'd0;
                    wait_count <= 18'd2;
                    state      <= ST_GAP66;
                end

                ST_GAP66: begin
                    if (wait_count != 0)
                        wait_count <= wait_count - 18'd1;
                    else
                        launch_serial(8'h66, ST_GAP99);
                end

                ST_SERIAL: begin
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                    end else begin
                        ram_sck <= 1'b0;
                        if (serial_bits_left == 1) begin
                            ram_cs_n  <= 1'b1;
                            ram_dq_oe <= 4'd0;
                            state     <= ST_SERIAL_HOLD;
                        end else begin
                            serial_shift     <= serial_shift << 1;
                            serial_bits_left <= serial_bits_left - 4'd1;
                            ram_dq_o[0]      <= serial_shift[6];
                        end
                    end
                end

                ST_SERIAL_HOLD: begin
                    ram_cs_n  <= 1'b1;
                    ram_sck   <= 1'b1;
                    ram_dq_oe <= 4'd0;
                    state     <= serial_next_state;
                    if (serial_next_state == ST_RESET_WAIT)
                        wait_count <= RESET_WAIT_CYCLES[17:0];
                    else
                        wait_count <= 18'd2;
                end

                ST_GAP99: begin
                    if (wait_count != 0)
                        wait_count <= wait_count - 18'd1;
                    else
                        launch_serial(8'h99, ST_RESET_WAIT);
                end

                ST_RESET_WAIT: begin
                    ram_cs_n  <= 1'b1;
                    ram_sck   <= 1'b1;
                    ram_dq_oe <= 4'd0;
                    if (wait_count != 0)
                        wait_count <= wait_count - 18'd1;
                    else begin
                        init_done <= 1'b1;
                        state <= ST_READY;
                    end
                end

                ST_READY: begin
                    ram_cs_n  <= 1'b1;
                    ram_sck   <= 1'b1;
                    ram_dq_oe <= 4'd0;
                    init_done <= 1'b1;
                    if (req_valid) begin
                        latched_write <= req_write;
                        latched_addr  <= req_write ? req_addr + {21'd0,first_lane} : req_addr;
                        latched_words <= (req_words == 0) ? 4'd1 : req_words;
                        if (req_write) begin
                            write_shift      <= req_wdata >> {first_lane,3'b000};
                            write_bytes_left <= byte_count;
                            write_half       <= 1'b0;
                        end
                        ram_cs_n          <= 1'b0;
                        ram_dq_oe         <= 4'b0001;
                        ram_sck           <= 1'b0;
                        ram_dq_o          <= {3'b000,(req_write ? 1'b0 : 1'b1)};
                        serial_shift      <= req_write ? 8'h38 : 8'hEB;
                        serial_bits_left  <= 4'd8;
                        state             <= ST_CMD;
                    end
                end

                // The command is serial; the address and payload are quad.
                ST_CMD: begin
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                    end else begin
                        ram_sck <= 1'b0;
                        if (serial_bits_left == 1) begin
                            quad_shift         <= {1'b0,latched_addr,8'd0};
                            quad_nibbles_left  <= 4'd6;
                            ram_dq_oe          <= 4'b1111;
                            ram_dq_o           <= {1'b0,latched_addr[22:20]};
                            state              <= ST_ADDR;
                        end else begin
                            serial_shift     <= serial_shift << 1;
                            serial_bits_left <= serial_bits_left - 4'd1;
                            ram_dq_o[0]      <= serial_shift[6];
                        end
                    end
                end

                ST_ADDR: begin
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                    end else begin
                        ram_sck <= 1'b0;
                        if (quad_nibbles_left == 1) begin
                            if (latched_write) begin
                                ram_dq_oe  <= 4'b1111;
                                ram_dq_o   <= write_shift[7:4];
                                write_half <= 1'b0;
                                state      <= ST_WRITE;
                            end else begin
                                ram_dq_oe          <= 4'b0000;
                                quad_nibbles_left  <= 4'd6;
                                state              <= ST_DUMMY;
                            end
                        end else begin
                            quad_shift        <= quad_shift << 4;
                            quad_nibbles_left <= quad_nibbles_left - 4'd1;
                            ram_dq_o          <= quad_shift[27:24];
                        end
                    end
                end

                ST_DUMMY: begin
                    ram_dq_oe <= 4'b0000;
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                    end else begin
                        ram_sck <= 1'b0;
                        if (quad_nibbles_left == 1) begin
                            read_nibbles_left <= {latched_words,3'b000};
                            read_nibble_index <= 3'd0;
                            rd_data           <= 32'd0;
                            state             <= ST_READ;
                        end else begin
                            quad_nibbles_left <= quad_nibbles_left - 4'd1;
                        end
                    end
                end

                ST_READ: begin
                    ram_dq_oe <= 4'b0000;
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                        case (read_nibble_index)
                            3'd0: read_hi_nibble <= ram_dq_i;
                            3'd1: rd_data[7:0] <= {read_hi_nibble,ram_dq_i};
                            3'd2: read_hi_nibble <= ram_dq_i;
                            3'd3: rd_data[15:8] <= {read_hi_nibble,ram_dq_i};
                            3'd4: read_hi_nibble <= ram_dq_i;
                            3'd5: rd_data[23:16] <= {read_hi_nibble,ram_dq_i};
                            3'd6: read_hi_nibble <= ram_dq_i;
                            default: begin
                                rd_data  <= {{read_hi_nibble,ram_dq_i},rd_data[23:0]};
                                rd_valid <= 1'b1;
                            end
                        endcase
                    end else begin
                        ram_sck <= 1'b0;
                        if (read_nibbles_left == 1) begin
                            ram_cs_n  <= 1'b1;
                            ram_dq_oe <= 4'd0;
                            state <= ST_FINISH;
                        end else begin
                            read_nibbles_left <= read_nibbles_left - 7'd1;
                            read_nibble_index <= read_nibble_index + 3'd1;
                        end
                    end
                end

                ST_WRITE: begin
                    if (!ram_sck) begin
                        ram_sck <= 1'b1;
                    end else begin
                        ram_sck <= 1'b0;
                        if (!write_half) begin
                            ram_dq_o   <= write_shift[3:0];
                            write_half <= 1'b1;
                        end else if (write_bytes_left == 1) begin
                            ram_cs_n  <= 1'b1;
                            ram_dq_oe <= 4'd0;
                            state     <= ST_FINISH;
                        end else begin
                            ram_dq_o          <= write_shift[15:12];
                            write_shift       <= write_shift >> 8;
                            write_bytes_left  <= write_bytes_left - 3'd1;
                            write_half        <= 1'b0;
                        end
                    end
                end

                ST_FINISH: begin
                    ram_cs_n   <= 1'b1;
                    ram_sck    <= 1'b1;
                    ram_dq_oe  <= 4'd0;
                    wait_count <= INTEROP_WAIT_CYCLES[17:0];
                    state      <= ST_INTEROP;
                end

                ST_INTEROP: begin
                    ram_cs_n  <= 1'b1;
                    ram_sck   <= 1'b1;
                    ram_dq_oe <= 4'd0;
                    if (wait_count != 0)
                        wait_count <= wait_count - 18'd1;
                    else begin
                        req_done <= 1'b1;
                        state <= ST_READY;
                    end
                end

                default: begin
                    init_done <= 1'b0;
                    state <= ST_POWER;
                    wait_count <= POWERUP_WAIT_CYCLES[17:0];
                end
            endcase
        end
    end
endmodule
