// Eight-bit SPI master with programmable mode, bit order, and divider.
module spi_master #(
    parameter DEFAULT_DIV = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire [7:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,
    input  wire        spi_miso,
    output reg         spi_mosi,
    output reg         spi_sck,
    output reg         spi_cs_n,
    output wire        irq
);
    reg [7:0] ctrl;
    reg [15:0] clk_div;
    reg [15:0] count;
    reg        busy;
    reg        done;
    reg        phase;
    reg [2:0]  bit_index;
    reg [7:0]  tx_data;
    reg [7:0]  rx_data;

    wire cpol = ctrl[0];
    wire cpha = ctrl[1];
    wire lsb_first = ctrl[2];
    assign irq = ctrl[3] & done;

    always @(*) begin
        case (bus_addr)
            8'h00: bus_rdata = {24'd0,rx_data};
            8'h04: bus_rdata = {30'd0,done,~busy};
            8'h08: bus_rdata = {24'd0,ctrl};
            8'h0C: bus_rdata = {16'd0,clk_div};
            8'h10: bus_rdata = {31'd0,~spi_cs_n};
            default: bus_rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl      <= 8'd0;
            clk_div   <= DEFAULT_DIV;
            count     <= 16'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            phase     <= 1'b0;
            bit_index <= 3'd7;
            tx_data   <= 8'd0;
            rx_data   <= 8'd0;
            spi_mosi  <= 1'b0;
            spi_sck   <= 1'b0;
            spi_cs_n  <= 1'b1;
        end else begin
            if (!busy)
                spi_sck <= cpol;

            if (busy) begin
                if (count != 0)
                    count <= count - 16'd1;
                else if (!phase) begin
                    // Leading clock edge.
                    spi_sck <= ~cpol;
                    phase <= 1'b1;
                    count <= (clk_div > 0) ? clk_div - 16'd1 : 16'd0;
                    if (!cpha)
                        rx_data[bit_index] <= spi_miso;
                end else begin
                    // Trailing edge. Mode with CPHA=1 samples here.
                    spi_sck <= cpol;
                    phase <= 1'b0;
                    count <= (clk_div > 0) ? clk_div - 16'd1 : 16'd0;
                    if (cpha)
                        rx_data[bit_index] <= spi_miso;

                    if ((!lsb_first && bit_index == 3'd0) ||
                        ( lsb_first && bit_index == 3'd7)) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else if (lsb_first) begin
                        bit_index <= bit_index + 3'd1;
                        spi_mosi <= tx_data[bit_index + 3'd1];
                    end else begin
                        bit_index <= bit_index - 3'd1;
                        spi_mosi <= tx_data[bit_index - 3'd1];
                    end
                end
            end

            if (bus_valid && |bus_wstrb) begin
                case (bus_addr)
                    8'h00: if (bus_wstrb[0] && !busy) begin
                        tx_data   <= bus_wdata[7:0];
                        rx_data   <= 8'd0;
                        bit_index <= lsb_first ? 3'd0 : 3'd7;
                        spi_mosi  <= lsb_first ? bus_wdata[0] : bus_wdata[7];
                        spi_sck   <= cpol;
                        phase     <= 1'b0;
                        count     <= (clk_div > 0) ? clk_div - 16'd1 : 16'd0;
                        busy      <= 1'b1;
                        done      <= 1'b0;
                    end
                    8'h08: if (bus_wstrb[0]) begin
                        ctrl <= bus_wdata[7:0];
                        if (bus_wdata[7]) done <= 1'b0;
                    end
                    8'h0C: begin
                        if (bus_wstrb[0]) clk_div[7:0]  <= bus_wdata[7:0];
                        if (bus_wstrb[1]) clk_div[15:8] <= bus_wdata[15:8];
                    end
                    8'h10: if (bus_wstrb[0]) spi_cs_n <= ~bus_wdata[0];
                    default: ;
                endcase
            end
        end
    end
endmodule
