// One-line instruction prefetch cache; FENCE.I invalidates the line.
module icache #(
    parameter LINE_WORDS = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        invalidate,

    input  wire        cpu_valid,
    input  wire [31:0] cpu_addr,
    output reg         cpu_ready,
    output reg  [31:0] cpu_rdata,

    output reg         ram_req,
    output reg  [31:0] ram_addr,
    output reg  [3:0]  ram_words,
    input  wire        ram_ready,
    input  wire        ram_rd_valid,
    input  wire [31:0] ram_rd_data,
    input  wire        ram_done
);

    localparam ST_IDLE = 2'd0;
    localparam ST_REQ  = 2'd1;
    localparam ST_FILL = 2'd2;
    localparam ST_DROP = 2'd3;
    localparam [31:0] LINE_MASK = ~(LINE_WORDS*4 - 1);
    localparam INDEX_BITS = (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS);

    reg [1:0] state;
    reg cache_valid;
    reg [31:0] cache_base;
    reg [INDEX_BITS-1:0] requested_index;
    reg [INDEX_BITS-1:0] fill_index;
    reg [31:0] line [0:LINE_WORDS-1];

    wire [31:0] request_base = cpu_addr & LINE_MASK;
    wire [INDEX_BITS-1:0] request_index = cpu_addr[INDEX_BITS+1:2];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            cache_valid    <= 1'b0;
            cache_base     <= 32'd0;
            requested_index<= {INDEX_BITS{1'b0}};
            fill_index     <= {INDEX_BITS{1'b0}};
            cpu_ready      <= 1'b0;
            cpu_rdata      <= 32'd0;
            ram_req        <= 1'b0;
            ram_addr       <= 32'd0;
            ram_words      <= LINE_WORDS;
            for (i = 0; i < LINE_WORDS; i = i + 1)
                line[i] <= 32'd0;
        end else begin
            cpu_ready <= 1'b0;
            ram_req   <= 1'b0;

            if (invalidate)
                cache_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (cpu_valid) begin
                        if (cache_valid && cache_base == request_base) begin
                            cpu_rdata <= line[request_index];
                            cpu_ready <= 1'b1;
                            state <= ST_DROP;
                        end else begin
                            requested_index<= request_index;
                            cache_base     <= request_base;
                            fill_index     <= {INDEX_BITS{1'b0}};
                            // Keep the full system address so the SoC can
                            // route one shared cache to flash or PSRAM.
                            ram_addr       <= request_base;
                            ram_words      <= LINE_WORDS;
                            state          <= ST_REQ;
                        end
                    end
                end

                ST_REQ: begin
                    ram_req <= 1'b1;
                    if (ram_ready)
                        state <= ST_FILL;
                end

                ST_FILL: begin
                    if (ram_rd_valid) begin
                        line[fill_index] <= ram_rd_data;
                        fill_index <= fill_index + 1'b1;
                    end
                    if (ram_done) begin
                        cache_valid <= 1'b1;
                        // Some memory controllers assert rd_valid for the last
                        // word in the cycle immediately before/with done. The
                        // line-array write is nonblocking, so bypass that beat
                        // when it is the word the CPU originally requested.
                        if (ram_rd_valid && fill_index == requested_index)
                            cpu_rdata <= ram_rd_data;
                        else
                            cpu_rdata <= line[requested_index];
                        cpu_ready   <= 1'b1;
                        state       <= ST_DROP;
                    end
                end

                ST_DROP: begin
                    // CPU keeps mem_valid asserted until it observes cpu_ready.
                    // Waiting for it to drop prevents a duplicate transaction.
                    if (!cpu_valid)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
