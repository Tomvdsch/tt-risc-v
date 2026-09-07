// Compact 8-N-1 UART with a one-byte RX holding register.
module uart #(
    parameter integer DEFAULT_DIV = 278
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,
    input  wire        uart_rx,
    output reg         uart_tx,
    output wire        irq
);
    reg [15:0] baud_div;
    reg [1:0] ctrl;

    reg        tx_busy;
    reg [9:0]  tx_shift;
    reg [3:0]  tx_bit;
    reg [15:0] tx_count;

    reg        rx_meta;
    reg        rx_sync;
    reg        rx_prev;
    reg        rx_busy;
    reg [1:0]  rx_state;
    reg [2:0]  rx_bit;
    reg [15:0] rx_count;
    reg [7:0]  rx_shift;
    reg [7:0]  rx_data;
    reg        rx_valid;
    reg        rx_overrun;

    localparam RX_START = 2'd0;
    localparam RX_DATA  = 2'd1;
    localparam RX_STOP  = 2'd2;

    assign irq = (ctrl[0] & rx_valid) | (ctrl[1] & ~tx_busy);

    always @(*) begin
        case (bus_addr)
            8'h00: bus_rdata = {24'd0,rx_data};
            8'h04: bus_rdata = {29'd0,rx_overrun,rx_valid,~tx_busy};
            8'h08: bus_rdata = {30'd0,ctrl};
            8'h0C: bus_rdata = {16'd0,baud_div};
            default: bus_rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_div   <= DEFAULT_DIV[15:0];
            ctrl       <= 2'b01;
            tx_busy    <= 1'b0;
            tx_shift   <= 10'h3FF;
            tx_bit     <= 4'd0;
            tx_count   <= 16'd0;
            uart_tx    <= 1'b1;
            rx_meta    <= 1'b1;
            rx_sync    <= 1'b1;
            rx_prev    <= 1'b1;
            rx_busy    <= 1'b0;
            rx_state   <= RX_START;
            rx_bit     <= 3'd0;
            rx_count   <= 16'd0;
            rx_shift   <= 8'd0;
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
            rx_overrun <= 1'b0;
        end else begin
            // Two-flop input synchronizer.
            rx_meta <= uart_rx;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;

            // TX engine.
            if (tx_busy) begin
                if (tx_count != 0)
                    tx_count <= tx_count - 16'd1;
                else if (tx_bit == 4'd9) begin
                    tx_busy <= 1'b0;
                    uart_tx <= 1'b1;
                end else begin
                    tx_bit   <= tx_bit + 4'd1;
                    uart_tx  <= tx_shift[tx_bit + 1'b1];
                    tx_count <= (baud_div > 0) ? baud_div - 16'd1 : 16'd0;
                end
            end

            // RX engine: detect a falling edge, then sample in the center of
            // each bit. Oversampling is intentionally omitted to save area.
            if (!rx_busy) begin
                if (rx_prev && !rx_sync) begin
                    rx_busy  <= 1'b1;
                    rx_state <= RX_START;
                    rx_count <= baud_div >> 1;
                    rx_bit   <= 3'd0;
                end
            end else if (rx_count != 0) begin
                rx_count <= rx_count - 16'd1;
            end else begin
                case (rx_state)
                    RX_START: begin
                        if (!rx_sync) begin
                            rx_state <= RX_DATA;
                            rx_count <= (baud_div > 0) ? baud_div - 16'd1 : 16'd0;
                        end else
                            rx_busy <= 1'b0; // false start
                    end
                    RX_DATA: begin
                        rx_shift[rx_bit] <= rx_sync;
                        rx_count <= (baud_div > 0) ? baud_div - 16'd1 : 16'd0;
                        if (rx_bit == 3'd7)
                            rx_state <= RX_STOP;
                        else
                            rx_bit <= rx_bit + 3'd1;
                    end
                    RX_STOP: begin
                        rx_busy <= 1'b0;
                        if (rx_sync) begin
                            if (rx_valid)
                                rx_overrun <= 1'b1;
                            rx_data  <= rx_shift;
                            rx_valid <= 1'b1;
                        end
                    end
                    default: rx_busy <= 1'b0;
                endcase
            end

            // MMIO side effects.
            if (bus_valid && |bus_wstrb) begin
                case (bus_addr)
                    8'h00: begin
                        if (bus_wstrb[0] && !tx_busy) begin
                            tx_shift <= {1'b1,bus_wdata[7:0],1'b0};
                            tx_bit   <= 4'd0;
                            uart_tx  <= 1'b0;
                            tx_busy  <= 1'b1;
                            tx_count <= (baud_div > 0) ? baud_div - 16'd1 : 16'd0;
                        end
                    end
                    8'h08: if (bus_wstrb[0]) begin
                        ctrl <= bus_wdata[1:0];
                        if (bus_wdata[2]) rx_overrun <= 1'b0;
                    end
                    8'h0C: begin
                        if (bus_wstrb[0]) baud_div[7:0]  <= bus_wdata[7:0];
                        if (bus_wstrb[1]) baud_div[15:8] <= bus_wdata[15:8];
                    end
                    default: ;
                endcase
            end
            if (bus_valid && !(|bus_wstrb) && bus_addr == 8'h00)
                rx_valid <= 1'b0;
        end
    end
endmodule
