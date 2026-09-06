// Read-only 03h, mode-0 SPI flash controller.
module spi_flash (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid,
    input  wire [22:0] req_addr,
    input  wire [3:0]  req_words, // 1..8 words
    output wire        req_ready,
    output reg         req_done,
    output reg         rd_valid,
    output reg  [31:0] rd_data,

    output reg         flash_cs_n,
    output reg         flash_mosi,
    output reg         flash_sck,
    input  wire        flash_miso
);

    localparam ST_IDLE   = 3'd0;
    localparam ST_TX     = 3'd1;
    localparam ST_READ   = 3'd2;
    localparam ST_FINISH = 3'd3;

    reg [2:0] state;
    reg       phase;
    reg [31:0] tx_shift;
    reg [5:0]  tx_bits_left;
    reg [8:0]  read_bits_left;
    reg [2:0]  bit_in_byte;
    reg [7:0]  byte_shift;
    reg [1:0]  byte_in_word;
    reg [31:0] read_word;
    reg [3:0]  latched_words;

    // Level handshake: the selected master holds req_valid until this is high.
    assign req_ready = (state == ST_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            phase          <= 1'b0;
            req_done       <= 1'b0;
            rd_valid       <= 1'b0;
            rd_data        <= 32'd0;
            flash_cs_n     <= 1'b1;
            flash_mosi     <= 1'b0;
            flash_sck      <= 1'b0;
            tx_shift       <= 32'd0;
            tx_bits_left   <= 6'd0;
            read_bits_left <= 9'd0;
            bit_in_byte    <= 3'd0;
            byte_shift     <= 8'd0;
            byte_in_word   <= 2'd0;
            read_word      <= 32'd0;
            latched_words  <= 4'd1;
        end else begin
            req_done <= 1'b0;
            rd_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    flash_cs_n <= 1'b1;
                    flash_sck  <= 1'b0;
                    phase      <= 1'b0;
                    if (req_valid) begin
                        latched_words <= (req_words == 0) ? 4'd1 : req_words;
                        tx_shift      <= {8'h03,1'b0,req_addr};
                        tx_bits_left  <= 6'd32;
                        flash_mosi    <= 1'b0; // MSB of 0x03
                        flash_cs_n    <= 1'b0;
                        state         <= ST_TX;
                    end
                end

                ST_TX: begin
                    if (!phase) begin
                        flash_sck <= 1'b1;
                        phase <= 1'b1;
                    end else begin
                        flash_sck <= 1'b0;
                        phase <= 1'b0;
                        if (tx_bits_left == 1) begin
                            read_bits_left <= {latched_words,5'b00000}; // words*32
                            bit_in_byte    <= 3'd0;
                            byte_in_word   <= 2'd0;
                            byte_shift     <= 8'd0;
                            read_word      <= 32'd0;
                            state          <= ST_READ;
                        end else begin
                            tx_shift      <= tx_shift << 1;
                            tx_bits_left  <= tx_bits_left - 6'd1;
                            flash_mosi    <= tx_shift[30];
                        end
                    end
                end

                ST_READ: begin
                    if (!phase) begin
                        // MISO is sampled on rising SCK for mode 0.
                        flash_sck  <= 1'b1;
                        phase      <= 1'b1;
                        byte_shift <= {byte_shift[6:0],flash_miso};
                        if (bit_in_byte == 3'd7) begin
                            case (byte_in_word)
                                2'd0: read_word[7:0]   <= {byte_shift[6:0],flash_miso};
                                2'd1: read_word[15:8]  <= {byte_shift[6:0],flash_miso};
                                2'd2: read_word[23:16] <= {byte_shift[6:0],flash_miso};
                                2'd3: begin
                                    read_word[31:24] <= {byte_shift[6:0],flash_miso};
                                    rd_data <= {{byte_shift[6:0],flash_miso},read_word[23:0]};
                                    rd_valid <= 1'b1;
                                end
                            endcase
                        end
                    end else begin
                        flash_sck <= 1'b0;
                        phase     <= 1'b0;
                        if (read_bits_left == 1) begin
                            flash_cs_n <= 1'b1;
                            state <= ST_FINISH;
                        end else begin
                            read_bits_left <= read_bits_left - 9'd1;
                            if (bit_in_byte == 3'd7) begin
                                bit_in_byte  <= 3'd0;
                                byte_in_word <= byte_in_word + 2'd1;
                            end else
                                bit_in_byte <= bit_in_byte + 3'd1;
                        end
                    end
                end

                ST_FINISH: begin
                    flash_cs_n <= 1'b1;
                    flash_sck  <= 1'b0;
                    req_done   <= 1'b1;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
