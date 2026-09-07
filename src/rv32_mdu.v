module rv32_mdu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [2:0]  funct3,
    input  wire [31:0] op_a,
    input  wire [31:0] op_b,
    output reg         busy,
    output reg         done,
    output reg  [31:0] result
);

    localparam ST_IDLE = 2'd0;
    localparam ST_MUL  = 2'd1;
    localparam ST_DIV  = 2'd2;

    reg [1:0]  state;
    reg [5:0]  count;
    reg [63:0] work;
    reg [31:0] operand;
    reg        negate_result;
    reg        high_or_remainder;
    reg        remainder_negative;

    wire [31:0] abs_a = op_a[31] ? (~op_a + 32'd1) : op_a;
    wire [31:0] abs_b = op_b[31] ? (~op_b + 32'd1) : op_b;

    wire [32:0] mul_sum = {1'b0,work[63:32]} +
                           (work[0] ? {1'b0,operand} : 33'd0);
    wire [63:0] mul_next = {mul_sum,work[31:1]};
    wire [63:0] mul_signed = negate_result ? (~mul_next + 64'd1) : mul_next;

    wire [32:0] div_trial = {work[63:32],work[31]};
    wire        div_ge = div_trial >= {1'b0,operand};
    wire [32:0] div_remainder = div_ge ?
        (div_trial - {1'b0,operand}) : div_trial;
    wire [63:0] div_next = {div_remainder[31:0],work[30:0],div_ge};
    wire [31:0] div_quotient = negate_result ?
        (~div_next[31:0] + 32'd1) : div_next[31:0];
    wire [31:0] div_remainder_signed = remainder_negative ?
        (~div_next[63:32] + 32'd1) : div_next[63:32];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            busy              <= 1'b0;
            done              <= 1'b0;
            result            <= 32'd0;
            count             <= 6'd0;
            work              <= 64'd0;
            operand           <= 32'd0;
            negate_result     <= 1'b0;
            high_or_remainder <= 1'b0;
            remainder_negative<= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        count <= 6'd0;
                        busy  <= 1'b1;
                        if (funct3 <= 3'b011) begin
                            high_or_remainder <= (funct3 != 3'b000);
                            if (funct3 == 3'b001) begin
                                work          <= {32'd0,abs_b};
                                operand       <= abs_a;
                                negate_result <= op_a[31] ^ op_b[31];
                            end else if (funct3 == 3'b010) begin
                                work          <= {32'd0,op_b};
                                operand       <= abs_a;
                                negate_result <= op_a[31];
                            end else begin
                                work          <= {32'd0,op_b};
                                operand       <= op_a;
                                negate_result <= 1'b0;
                            end
                            state <= ST_MUL;
                        end else if (op_b == 32'd0) begin
                            result <= (funct3 == 3'b100 || funct3 == 3'b101) ?
                                      32'hFFFF_FFFF : op_a;
                            busy   <= 1'b0;
                            done   <= 1'b1;
                        end else if ((funct3 == 3'b100 || funct3 == 3'b110) &&
                                     op_a == 32'h8000_0000 &&
                                     op_b == 32'hFFFF_FFFF) begin
                            result <= (funct3 == 3'b100) ? 32'h8000_0000 : 32'd0;
                            busy   <= 1'b0;
                            done   <= 1'b1;
                        end else begin
                            high_or_remainder <= (funct3 == 3'b110 || funct3 == 3'b111);
                            if (funct3 == 3'b100 || funct3 == 3'b110) begin
                                work          <= {32'd0,abs_a};
                                operand       <= abs_b;
                                negate_result <= op_a[31] ^ op_b[31];
                                remainder_negative <= op_a[31];
                            end else begin
                                work          <= {32'd0,op_a};
                                operand       <= op_b;
                                negate_result <= 1'b0;
                                remainder_negative <= 1'b0;
                            end
                            state <= ST_DIV;
                        end
                    end
                end

                ST_MUL: begin
                    work  <= mul_next;
                    count <= count + 6'd1;
                    if (count == 6'd31) begin
                        result <= high_or_remainder ? mul_signed[63:32]
                                                    : mul_signed[31:0];
                        busy   <= 1'b0;
                        done   <= 1'b1;
                        state  <= ST_IDLE;
                    end
                end

                ST_DIV: begin
                    work  <= div_next;
                    count <= count + 6'd1;
                    if (count == 6'd31) begin
                        if (high_or_remainder)
                            result <= (funct3 == 3'b110) ?
                                      div_remainder_signed : div_next[63:32];
                        else
                            result <= div_quotient;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
