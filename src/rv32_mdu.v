// -----------------------------------------------------------------------------
// rv32_mdu.v
// Small iterative RV32M multiply/divide unit.
//
// Area is intentionally traded for latency: multiply and divide each take up to
// 32 clocks instead of instantiating a large combinational multiplier/divider.
// Set ENABLE_M=0 in rv32_core to remove this block from the ASIC if area is tight.
// -----------------------------------------------------------------------------
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

    reg [1:0] state;
    reg [2:0] op;
    reg [5:0] count;

    // Multiply state.
    reg [63:0] mul_acc;
    reg [63:0] mul_mcand;
    reg [31:0] mul_mplier;
    reg        mul_neg;
    reg        mul_high;

    wire [63:0] mul_acc_next = mul_mplier[0] ? (mul_acc + mul_mcand) : mul_acc;
    wire [63:0] mul_product_signed = mul_neg ? (~mul_acc_next + 64'd1) : mul_acc_next;

    // Divide state.
    reg [31:0] div_quot;
    reg [32:0] div_rem;
    reg [31:0] div_divisor;
    reg        div_quot_neg;
    reg        div_rem_neg;
    reg        div_want_rem;

    wire [32:0] div_rem_shift = {div_rem[31:0], div_quot[31]};
    wire        div_ge         = (div_rem_shift >= {1'b0, div_divisor});
    wire [32:0] div_rem_next   = div_ge ? (div_rem_shift - {1'b0, div_divisor}) : div_rem_shift;
    wire [31:0] div_quot_next  = {div_quot[30:0], div_ge};
    wire [31:0] div_q_signed   = div_quot_neg ? (~div_quot_next + 32'd1) : div_quot_next;
    wire [31:0] div_r_unsigned = div_rem_next[31:0];
    wire [31:0] div_r_signed   = div_rem_neg ? (~div_r_unsigned + 32'd1) : div_r_unsigned;

    reg [31:0] abs_a;
    reg [31:0] abs_b;
    reg        sign_a;
    reg        sign_b;

    always @(*) begin
        sign_a = op_a[31];
        sign_b = op_b[31];
        abs_a = sign_a ? (~op_a + 32'd1) : op_a;
        abs_b = sign_b ? (~op_b + 32'd1) : op_b;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            result        <= 32'd0;
            count         <= 6'd0;
            op            <= 3'd0;
            mul_acc       <= 64'd0;
            mul_mcand     <= 64'd0;
            mul_mplier    <= 32'd0;
            mul_neg       <= 1'b0;
            mul_high      <= 1'b0;
            div_quot      <= 32'd0;
            div_rem       <= 33'd0;
            div_divisor   <= 32'd0;
            div_quot_neg  <= 1'b0;
            div_rem_neg   <= 1'b0;
            div_want_rem  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        op    <= funct3;
                        count <= 6'd0;
                        busy  <= 1'b1;

                        if (funct3 <= 3'b011) begin
                            // MUL is allowed to use unsigned operands because the
                            // low 32 bits are identical for signed/unsigned math.
                            mul_acc    <= 64'd0;
                            mul_high   <= (funct3 != 3'b000);
                            if (funct3 == 3'b001) begin       // MULH: signed*signed
                                mul_mcand  <= {32'd0, abs_a};
                                mul_mplier <= abs_b;
                                mul_neg    <= sign_a ^ sign_b;
                            end else if (funct3 == 3'b010) begin // MULHSU
                                mul_mcand  <= {32'd0, abs_a};
                                mul_mplier <= op_b;
                                mul_neg    <= sign_a;
                            end else begin                   // MUL or MULHU
                                mul_mcand  <= {32'd0, op_a};
                                mul_mplier <= op_b;
                                mul_neg    <= 1'b0;
                            end
                            state <= ST_MUL;
                        end else begin
                            // Division corner cases are resolved immediately.
                            if (op_b == 32'd0) begin
                                if (funct3 == 3'b100 || funct3 == 3'b101)
                                    result <= 32'hFFFF_FFFF; // DIV/DIVU by zero
                                else
                                    result <= op_a;          // REM/REMU by zero
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else if ((funct3 == 3'b100 || funct3 == 3'b110) &&
                                         op_a == 32'h8000_0000 && op_b == 32'hFFFF_FFFF) begin
                                result <= (funct3 == 3'b100) ? 32'h8000_0000 : 32'd0;
                                busy   <= 1'b0;
                                done   <= 1'b1;
                                state  <= ST_IDLE;
                            end else begin
                                div_rem      <= 33'd0;
                                div_want_rem <= (funct3 == 3'b110 || funct3 == 3'b111);
                                if (funct3 == 3'b100 || funct3 == 3'b110) begin
                                    div_quot     <= abs_a;
                                    div_divisor  <= abs_b;
                                    div_quot_neg <= sign_a ^ sign_b;
                                    div_rem_neg  <= sign_a;
                                end else begin
                                    div_quot     <= op_a;
                                    div_divisor  <= op_b;
                                    div_quot_neg <= 1'b0;
                                    div_rem_neg  <= 1'b0;
                                end
                                state <= ST_DIV;
                            end
                        end
                    end
                end

                ST_MUL: begin
                    mul_acc    <= mul_acc_next;
                    mul_mcand  <= mul_mcand << 1;
                    mul_mplier <= mul_mplier >> 1;
                    count      <= count + 6'd1;
                    if (count == 6'd31) begin
                        result <= mul_high ? mul_product_signed[63:32]
                                           : mul_product_signed[31:0];
                        busy   <= 1'b0;
                        done   <= 1'b1;
                        state  <= ST_IDLE;
                    end
                end

                ST_DIV: begin
                    div_rem  <= div_rem_next;
                    div_quot <= div_quot_next;
                    count    <= count + 6'd1;
                    if (count == 6'd31) begin
                        result <= div_want_rem ? div_r_signed : div_q_signed;
                        busy   <= 1'b0;
                        done   <= 1'b1;
                        state  <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
