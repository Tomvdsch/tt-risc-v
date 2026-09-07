// Multi-cycle RV32I core with optional M/A, Zicsr, Zifencei, and M/U modes.
module rv32_core #(
    parameter ENABLE_M        = 1,
    parameter ENABLE_A        = 0,
    parameter ENABLE_U        = 0,
    parameter ENABLE_COUNTERS = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] reset_vector,

    // Machine interrupt inputs.
    input  wire        irq_software,
    input  wire        irq_timer,
    input  wire        irq_external,
    input  wire [63:0] time_value,

    // Single-master memory bus.
    output reg         mem_valid,
    output reg         mem_instr,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata,

    // Pulse when FENCE.I executes so the external instruction cache can flush.
    output reg         fence_i,

    output wire [31:0] debug_pc
);

    localparam ST_FETCH      = 4'd0;
    localparam ST_FETCH_WAIT = 4'd1;
    localparam ST_EXEC       = 4'd2;
    localparam ST_MEM_WAIT   = 4'd3;
    localparam ST_M_WAIT     = 4'd4;
    localparam ST_WFI        = 4'd5;
    localparam ST_A_READ     = 4'd6;
    localparam ST_A_WRITE_REQ= 4'd7;
    localparam ST_A_WRITE_WAIT=4'd8;
    localparam ST_READ_RS1   = 4'd9;
    localparam ST_READ_RS2   = 4'd10;

    reg [3:0]  state;
    reg [31:0] pc;
    reg [31:0] instr;
    reg [31:0] regs [1:31];
    reg [31:0] operand_rs1;
    reg [31:0] operand_rs2;

    reg [4:0]  pending_rd;
    reg [2:0]  pending_load_funct3;
    reg [1:0]  pending_addr_low;
    reg        pending_is_load;

    // RV32A state. With a single CPU memory master, keeping mem_valid asserted
    // for each phase makes the read/modify/write sequence indivisible with
    // respect to all current bus agents. Any normal store conservatively
    // invalidates the LR reservation.
    reg        reservation_valid;
    reg [31:2] reservation_addr;
    reg [4:0]  pending_a_funct5;
    reg [31:0] pending_a_addr;
    reg [31:0] pending_a_operand;
    reg [31:0] pending_a_old;
    reg [31:0] pending_a_new;

    // Machine CSRs.
    reg [31:0] csr_mstatus;
    reg [31:0] csr_mie;
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mscratch;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    reg [31:0] csr_mtval;
    reg [31:0] csr_mcounteren;
    reg [63:0] csr_mcycle;
    reg [63:0] csr_minstret;
    reg [1:0]  priv_mode;

    assign debug_pc = pc;

    wire [4:0] rs1_idx = instr[19:15];
    wire [4:0] rs2_idx = instr[24:20];
    wire [4:0] rd_idx  = instr[11:7];
    wire [6:0] opcode  = instr[6:0];
    wire [2:0] funct3  = instr[14:12];
    wire [6:0] funct7  = instr[31:25];

    wire [4:0] reg_read_idx = (state == ST_READ_RS1) ? rs1_idx : rs2_idx;
    wire [31:0] reg_read_value = (reg_read_idx == 0) ? 32'd0 : regs[reg_read_idx];
    wire [31:0] rs1_val = operand_rs1;
    wire [31:0] rs2_val = operand_rs2;
    wire signed [31:0] s_rs1 = rs1_val;
    wire signed [31:0] s_rs2 = rs2_val;

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'd0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    wire [31:0] csr_mip = {20'd0, irq_external, 3'd0, irq_timer, 3'd0, irq_software, 3'd0};
    wire irq_ext_pending = irq_external & csr_mie[11];
    wire irq_tmr_pending = irq_timer    & csr_mie[7];
    wire irq_swi_pending = irq_software & csr_mie[3];
    wire irq_any_enabled = irq_ext_pending | irq_tmr_pending | irq_swi_pending;
    wire irq_global_enable = (priv_mode != 2'b11) || csr_mstatus[3];

    // Optional RV32M unit.
    reg         mdu_start;
    reg  [2:0]  mdu_funct3;
    reg  [31:0] mdu_a;
    reg  [31:0] mdu_b;
    wire        mdu_done_i;
    wire [31:0] mdu_result_i;

    generate
        if (ENABLE_M) begin : gen_mdu
            rv32_mdu u_mdu (
                .clk(clk), .rst_n(rst_n), .start(mdu_start), .funct3(mdu_funct3),
                .op_a(mdu_a), .op_b(mdu_b), .busy(),
                .done(mdu_done_i), .result(mdu_result_i)
            );
        end else begin : gen_no_mdu
            assign mdu_done_i   = 1'b0;
            assign mdu_result_i = 32'd0;
        end
    endgenerate

    // CSR read mux. Unsupported CSRs read as zero, but the instruction decoder
    // separately checks csr_supported() and raises illegal-instruction.
    function [31:0] csr_read;
        input [11:0] addr;
        begin
            case (addr)
                12'h300: csr_read = csr_mstatus;
                12'h301: csr_read = 32'h4000_0100 |
                                      (ENABLE_M ? 32'h0000_1000 : 32'd0) |
                                      (ENABLE_A ? 32'h0000_0001 : 32'd0) |
                                      (ENABLE_U ? 32'h0010_0000 : 32'd0); // RV32 I [+M] [+A], M/U modes
                12'h304: csr_read = csr_mie;
                12'h305: csr_read = csr_mtvec;
                12'h306: csr_read = (ENABLE_U && ENABLE_COUNTERS) ?
                                      csr_mcounteren : 32'd0;
                12'h340: csr_read = csr_mscratch;
                12'h341: csr_read = csr_mepc;
                12'h342: csr_read = csr_mcause;
                12'h343: csr_read = csr_mtval;
                12'h344: csr_read = csr_mip;
                12'hB00: csr_read = ENABLE_COUNTERS ? csr_mcycle[31:0]   : 32'd0;
                12'hB02: csr_read = ENABLE_COUNTERS ? csr_minstret[31:0] : 32'd0;
                12'hB80: csr_read = ENABLE_COUNTERS ? csr_mcycle[63:32]   : 32'd0;
                12'hB82: csr_read = ENABLE_COUNTERS ? csr_minstret[63:32] : 32'd0;
                12'hC00: csr_read = ENABLE_COUNTERS ? csr_mcycle[31:0]   : 32'd0;
                12'hC01: csr_read = time_value[31:0];
                12'hC02: csr_read = ENABLE_COUNTERS ? csr_minstret[31:0] : 32'd0;
                12'hC80: csr_read = ENABLE_COUNTERS ? csr_mcycle[63:32]   : 32'd0;
                12'hC81: csr_read = time_value[63:32];
                12'hC82: csr_read = ENABLE_COUNTERS ? csr_minstret[63:32] : 32'd0;
                12'hF11: csr_read = 32'd0;          // mvendorid
                12'hF12: csr_read = 32'd0;          // marchid
                12'hF13: csr_read = 32'h0000_0001;  // mimpid
                12'hF14: csr_read = 32'd0;          // mhartid = 0
                default: csr_read = 32'd0;
            endcase
        end
    endfunction

    function csr_supported;
        input [11:0] addr;
        begin
            case (addr)
                12'h300,12'h301,12'h304,12'h305,12'h306,12'h340,12'h341,12'h342,
                12'h343,12'h344,12'hB00,12'hB02,12'hB80,12'hB82,
                12'hC00,12'hC01,12'hC02,12'hC80,12'hC81,12'hC82,
                12'hF11,12'hF12,12'hF13,12'hF14: csr_supported = 1'b1;
                default: csr_supported = 1'b0;
            endcase
        end
    endfunction

    function csr_writable;
        input [11:0] addr;
        begin
            case (addr)
                12'h300,12'h304,12'h305,12'h306,12'h340,12'h341,12'h342,12'h343,
                12'hB00,12'hB02,12'hB80,12'hB82: csr_writable = 1'b1;
                default: csr_writable = 1'b0;
            endcase
        end
    endfunction

    task write_csr;
        input [11:0] addr;
        input [31:0] value;
        begin
            case (addr)
                12'h300: begin
                    csr_mstatus[3] <= value[3];
                    csr_mstatus[7] <= value[7];
                    if (ENABLE_U && value[12:11] == 2'b00)
                        csr_mstatus[12:11] <= 2'b00;
                    else
                        csr_mstatus[12:11] <= 2'b11;
                end
                12'h304: csr_mie     <= value & 32'h0000_0888;
                12'h305: csr_mtvec   <= {value[31:2], (value[1:0] == 2'b01) ? 2'b01 : 2'b00};
                12'h306: if (ENABLE_U && ENABLE_COUNTERS)
                    csr_mcounteren <= value & 32'h0000_0007;
                12'h340: csr_mscratch<= value;
                12'h341: csr_mepc    <= {value[31:2], 2'b00};
                12'h342: csr_mcause  <= value;
                12'h343: csr_mtval   <= value;
                12'hB00: if (ENABLE_COUNTERS) csr_mcycle[31:0]    <= value;
                12'hB02: if (ENABLE_COUNTERS) csr_minstret[31:0]  <= value;
                12'hB80: if (ENABLE_COUNTERS) csr_mcycle[63:32]   <= value;
                12'hB82: if (ENABLE_COUNTERS) csr_minstret[63:32] <= value;
                default: ;
            endcase
        end
    endtask

    function csr_access_allowed;
        input [11:0] addr;
        begin
            csr_access_allowed = (priv_mode >= addr[9:8]);
            if (priv_mode == 2'b00 && addr[11:8] == 4'hC) begin
                case (addr[7:0])
                    8'h00,8'h80: csr_access_allowed = csr_mcounteren[0];
                    8'h01,8'h81: csr_access_allowed = csr_mcounteren[1];
                    8'h02,8'h82: csr_access_allowed = csr_mcounteren[2];
                    default: csr_access_allowed = 1'b0;
                endcase
            end
        end
    endfunction

    function [31:0] amo_result;
        input [4:0] funct5_in;
        input [31:0] old_value;
        input [31:0] operand;
        begin
            case (funct5_in)
                5'b00000: amo_result = old_value + operand; // AMOADD.W
                5'b00001: amo_result = operand;             // AMOSWAP.W
                5'b00100: amo_result = old_value ^ operand; // AMOXOR.W
                5'b01000: amo_result = old_value | operand; // AMOOR.W
                5'b01100: amo_result = old_value & operand; // AMOAND.W
                5'b10000: amo_result = ($signed(old_value) < $signed(operand)) ? old_value : operand; // AMOMIN.W
                5'b10100: amo_result = ($signed(old_value) > $signed(operand)) ? old_value : operand; // AMOMAX.W
                5'b11000: amo_result = (old_value < operand) ? old_value : operand; // AMOMINU.W
                5'b11100: amo_result = (old_value > operand) ? old_value : operand; // AMOMAXU.W
                default:  amo_result = old_value;
            endcase
        end
    endfunction

    function amo_funct5_supported;
        input [4:0] funct5_in;
        begin
            case (funct5_in)
                5'b00000,5'b00001,5'b00010,5'b00011,5'b00100,
                5'b01000,5'b01100,5'b10000,5'b10100,5'b11000,
                5'b11100: amo_funct5_supported = 1'b1;
                default:  amo_funct5_supported = 1'b0;
            endcase
        end
    endfunction

    task take_trap;
        input [31:0] cause;
        input [31:0] tval;
        input [31:0] epc;
        reg [31:0] vector_pc;
        begin
            csr_mepc       <= {epc[31:2], 2'b00};
            csr_mcause     <= cause;
            csr_mtval      <= tval;
            csr_mstatus[7] <= csr_mstatus[3]; // MPIE <- MIE
            csr_mstatus[3] <= 1'b0;           // MIE  <- 0
            csr_mstatus[12:11] <= priv_mode;   // MPP  <- interrupted mode
            priv_mode          <= 2'b11;       // enter Machine mode
            reservation_valid  <= 1'b0;
            if (cause[31] && csr_mtvec[1:0] == 2'b01)
                vector_pc = {csr_mtvec[31:2],2'b00} + ((cause & 32'h7FFF_FFFF) << 2);
            else
                vector_pc = {csr_mtvec[31:2],2'b00};
            pc        <= vector_pc;
            mem_valid <= 1'b0;
            state     <= ST_FETCH;
        end
    endtask

    reg [31:0] target;
    reg [31:0] eff_addr;
    reg [31:0] alu_result;
    reg        branch_take;
    reg [31:0] csr_old;
    reg [31:0] csr_new;
    reg [31:0] csr_src;
    reg        csr_do_write;
    reg        csr_illegal_write;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_FETCH;
            pc             <= reset_vector;
            instr          <= 32'h0000_0013;
            operand_rs1    <= 32'd0;
            operand_rs2    <= 32'd0;
            mem_valid      <= 1'b0;
            mem_instr      <= 1'b0;
            mem_addr       <= 32'd0;
            mem_wdata      <= 32'd0;
            mem_wstrb      <= 4'd0;
            fence_i        <= 1'b0;
            pending_rd     <= 5'd0;
            pending_load_funct3 <= 3'd0;
            pending_addr_low <= 2'd0;
            pending_is_load <= 1'b0;
            reservation_valid <= 1'b0;
            reservation_addr  <= 30'd0;
            pending_a_funct5  <= 5'd0;
            pending_a_addr    <= 32'd0;
            pending_a_operand <= 32'd0;
            pending_a_old     <= 32'd0;
            pending_a_new     <= 32'd0;
            csr_mstatus    <= 32'h0000_1800; // MPP=Machine, interrupts disabled
            csr_mie        <= 32'd0;
            csr_mtvec      <= 32'd0;
            csr_mscratch   <= 32'd0;
            csr_mepc       <= 32'd0;
            csr_mcause     <= 32'd0;
            csr_mtval      <= 32'd0;
            csr_mcounteren <= 32'd0;
            csr_mcycle     <= 64'd0;
            csr_minstret   <= 64'd0;
            priv_mode      <= 2'b11;
            mdu_start      <= 1'b0;
            mdu_funct3     <= 3'd0;
            mdu_a          <= 32'd0;
            mdu_b          <= 32'd0;
        end else begin
            fence_i   <= 1'b0;
            mdu_start <= 1'b0;
            if (ENABLE_COUNTERS)
                csr_mcycle <= csr_mcycle + 64'd1;

            case (state)
                ST_FETCH: begin
                    mem_valid <= 1'b0;
                    mem_wstrb <= 4'd0;
                    // Interrupts are sampled between instructions.
                    if (irq_global_enable && irq_any_enabled) begin
                        if (irq_ext_pending)
                            take_trap(32'h8000_000B, 32'd0, pc);
                        else if (irq_swi_pending)
                            take_trap(32'h8000_0003, 32'd0, pc);
                        else
                            take_trap(32'h8000_0007, 32'd0, pc);
                    end else if (pc[1:0] != 2'b00) begin
                        take_trap(32'd0, pc, pc); // instruction address misaligned
                    end else begin
                        mem_valid <= 1'b1;
                        mem_instr <= 1'b1;
                        mem_addr  <= pc;
                        mem_wdata <= 32'd0;
                        mem_wstrb <= 4'd0;
                        state     <= ST_FETCH_WAIT;
                    end
                end

                ST_FETCH_WAIT: begin
                    if (mem_ready) begin
                        mem_valid <= 1'b0;
                        instr     <= mem_rdata;
                        state     <= ST_READ_RS1;
                    end
                end

                ST_READ_RS1: begin
                    operand_rs1 <= reg_read_value;
                    state <= ST_READ_RS2;
                end

                ST_READ_RS2: begin
                    operand_rs2 <= reg_read_value;
                    state <= ST_EXEC;
                end

                ST_EXEC: begin
                    // Defaults used by several decode paths.
                    target            = 32'd0;
                    eff_addr          = 32'd0;
                    alu_result        = 32'd0;
                    branch_take       = 1'b0;
                    csr_old           = 32'd0;
                    csr_new           = 32'd0;
                    csr_src           = 32'd0;
                    csr_do_write      = 1'b0;
                    csr_illegal_write = 1'b0;

                    case (opcode)
                        7'b0110111: begin // LUI
                            if (rd_idx != 0) regs[rd_idx] <= imm_u;
                            pc <= pc + 32'd4;
                            if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                            state <= ST_FETCH;
                        end

                        7'b0010111: begin // AUIPC
                            if (rd_idx != 0) regs[rd_idx] <= pc + imm_u;
                            pc <= pc + 32'd4;
                            if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                            state <= ST_FETCH;
                        end

                        7'b1101111: begin // JAL
                            target = pc + imm_j;
                            if (target[1:0] != 2'b00)
                                take_trap(32'd0, target, pc);
                            else begin
                                if (rd_idx != 0) regs[rd_idx] <= pc + 32'd4;
                                pc <= target;
                                if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                state <= ST_FETCH;
                            end
                        end

                        7'b1100111: begin // JALR
                            if (funct3 != 3'b000)
                                take_trap(32'd2, instr, pc);
                            else begin
                                target = (rs1_val + imm_i) & 32'hFFFF_FFFE;
                                if (target[1:0] != 2'b00)
                                    take_trap(32'd0, target, pc);
                                else begin
                                    if (rd_idx != 0) regs[rd_idx] <= pc + 32'd4;
                                    pc <= target;
                                    if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                    state <= ST_FETCH;
                                end
                            end
                        end

                        7'b1100011: begin // Branches
                            case (funct3)
                                3'b000: branch_take = (rs1_val == rs2_val);       // BEQ
                                3'b001: branch_take = (rs1_val != rs2_val);       // BNE
                                3'b100: branch_take = (s_rs1 < s_rs2);            // BLT
                                3'b101: branch_take = (s_rs1 >= s_rs2);           // BGE
                                3'b110: branch_take = (rs1_val < rs2_val);        // BLTU
                                3'b111: branch_take = (rs1_val >= rs2_val);       // BGEU
                                default: branch_take = 1'b0;
                            endcase
                            if (funct3 == 3'b010 || funct3 == 3'b011)
                                take_trap(32'd2, instr, pc);
                            else begin
                                target = branch_take ? (pc + imm_b) : (pc + 32'd4);
                                if (target[1:0] != 2'b00)
                                    take_trap(32'd0, target, pc);
                                else begin
                                    pc <= target;
                                    if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                    state <= ST_FETCH;
                                end
                            end
                        end

                        7'b0000011: begin // Loads
                            eff_addr = rs1_val + imm_i;
                            if ((funct3 == 3'b001 || funct3 == 3'b101) && eff_addr[0])
                                take_trap(32'd4, eff_addr, pc);
                            else if (funct3 == 3'b010 && eff_addr[1:0] != 2'b00)
                                take_trap(32'd4, eff_addr, pc);
                            else if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111)
                                take_trap(32'd2, instr, pc);
                            else begin
                                mem_valid <= 1'b1;
                                mem_instr <= 1'b0;
                                mem_addr  <= eff_addr;
                                mem_wdata <= 32'd0;
                                mem_wstrb <= 4'd0;
                                pending_rd <= rd_idx;
                                pending_load_funct3 <= funct3;
                                pending_addr_low <= eff_addr[1:0];
                                pending_is_load <= 1'b1;
                                state <= ST_MEM_WAIT;
                            end
                        end

                        7'b0100011: begin // Stores
                            eff_addr = rs1_val + imm_s;
                            reservation_valid <= 1'b0;
                            if (funct3 == 3'b001 && eff_addr[0])
                                take_trap(32'd6, eff_addr, pc);
                            else if (funct3 == 3'b010 && eff_addr[1:0] != 2'b00)
                                take_trap(32'd6, eff_addr, pc);
                            else if (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010) begin
                                mem_valid <= 1'b1;
                                mem_instr <= 1'b0;
                                mem_addr  <= eff_addr;
                                pending_is_load <= 1'b0;
                                case (funct3)
                                    3'b000: begin // SB
                                        mem_wstrb <= 4'b0001 << eff_addr[1:0];
                                        mem_wdata <= rs2_val << {eff_addr[1:0],3'b000};
                                    end
                                    3'b001: begin // SH
                                        mem_wstrb <= 4'b0011 << eff_addr[1:0];
                                        mem_wdata <= rs2_val << {eff_addr[1:0],3'b000};
                                    end
                                    default: begin // SW
                                        mem_wstrb <= 4'b1111;
                                        mem_wdata <= rs2_val;
                                    end
                                endcase
                                state <= ST_MEM_WAIT;
                            end else
                                take_trap(32'd2, instr, pc);
                        end

                        7'b0101111: begin // RV32A word atomics
                            eff_addr = rs1_val;
                            if (!ENABLE_A || funct3 != 3'b010 ||
                                !amo_funct5_supported(instr[31:27]) ||
                                (instr[31:27] == 5'b00010 && rs2_idx != 0)) begin
                                take_trap(32'd2, instr, pc);
                            end else if (eff_addr[1:0] != 2'b00) begin
                                take_trap((instr[31:27] == 5'b00010) ? 32'd4 : 32'd6,
                                          eff_addr, pc);
                            end else if (instr[31:27] == 5'b00011) begin // SC.W
                                reservation_valid <= 1'b0;
                                if (reservation_valid && reservation_addr == eff_addr[31:2]) begin
                                    mem_valid <= 1'b1;
                                    mem_instr <= 1'b0;
                                    mem_addr  <= eff_addr;
                                    mem_wdata <= rs2_val;
                                    mem_wstrb <= 4'b1111;
                                    pending_rd <= rd_idx;
                                    pending_a_funct5 <= 5'b00011;
                                    state <= ST_A_WRITE_WAIT;
                                end else begin
                                    if (rd_idx != 0) regs[rd_idx] <= 32'd1;
                                    pc <= pc + 32'd4;
                                    if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                    state <= ST_FETCH;
                                end
                            end else begin // LR.W or an AMO read phase
                                mem_valid <= 1'b1;
                                mem_instr <= 1'b0;
                                mem_addr  <= eff_addr;
                                mem_wdata <= 32'd0;
                                mem_wstrb <= 4'd0;
                                pending_rd <= rd_idx;
                                pending_a_funct5 <= instr[31:27];
                                pending_a_addr <= eff_addr;
                                pending_a_operand <= rs2_val;
                                state <= ST_A_READ;
                            end
                        end

                        7'b0010011: begin // OP-IMM
                            case (funct3)
                                3'b000: alu_result = rs1_val + imm_i; // ADDI
                                3'b010: alu_result = (s_rs1 < $signed(imm_i)) ? 32'd1 : 32'd0; // SLTI
                                3'b011: alu_result = (rs1_val < imm_i) ? 32'd1 : 32'd0; // SLTIU
                                3'b100: alu_result = rs1_val ^ imm_i;
                                3'b110: alu_result = rs1_val | imm_i;
                                3'b111: alu_result = rs1_val & imm_i;
                                3'b001: alu_result = rs1_val << instr[24:20];
                                3'b101: alu_result = instr[30] ?
                                    (rs1_val[31] ? ~(~rs1_val >> instr[24:20]) :
                                                   (rs1_val >> instr[24:20])) :
                                    (rs1_val >> instr[24:20]);
                                default: alu_result = 32'd0;
                            endcase
                            if ((funct3 == 3'b001 && funct7 != 7'b0000000) ||
                                (funct3 == 3'b101 && !(funct7 == 7'b0000000 || funct7 == 7'b0100000)))
                                take_trap(32'd2, instr, pc);
                            else begin
                                if (rd_idx != 0) regs[rd_idx] <= alu_result;
                                pc <= pc + 32'd4;
                                if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                state <= ST_FETCH;
                            end
                        end

                        7'b0110011: begin // OP and RV32M
                            if (funct7 == 7'b0000001) begin
                                if (ENABLE_M) begin
                                    mdu_start  <= 1'b1;
                                    mdu_funct3 <= funct3;
                                    mdu_a      <= rs1_val;
                                    mdu_b      <= rs2_val;
                                    pending_rd <= rd_idx;
                                    state      <= ST_M_WAIT;
                                end else
                                    take_trap(32'd2, instr, pc);
                            end else begin
                                case (funct3)
                                    3'b000: alu_result = funct7[5] ? (rs1_val - rs2_val) : (rs1_val + rs2_val);
                                    3'b001: alu_result = rs1_val << rs2_val[4:0];
                                    3'b010: alu_result = (s_rs1 < s_rs2) ? 32'd1 : 32'd0;
                                    3'b011: alu_result = (rs1_val < rs2_val) ? 32'd1 : 32'd0;
                                    3'b100: alu_result = rs1_val ^ rs2_val;
                                    3'b101: alu_result = funct7[5] ?
                                        (rs1_val[31] ? ~(~rs1_val >> rs2_val[4:0]) :
                                                       (rs1_val >> rs2_val[4:0])) :
                                        (rs1_val >> rs2_val[4:0]);
                                    3'b110: alu_result = rs1_val | rs2_val;
                                    3'b111: alu_result = rs1_val & rs2_val;
                                    default: alu_result = 32'd0;
                                endcase
                                if (!((funct7 == 7'b0000000) ||
                                      (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))))
                                    take_trap(32'd2, instr, pc);
                                else begin
                                    if (rd_idx != 0) regs[rd_idx] <= alu_result;
                                    pc <= pc + 32'd4;
                                    if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                    state <= ST_FETCH;
                                end
                            end
                        end

                        7'b0001111: begin // FENCE / FENCE.I
                            if (funct3 == 3'b000 || funct3 == 3'b001) begin
                                if (funct3 == 3'b001)
                                    fence_i <= 1'b1;
                                pc <= pc + 32'd4;
                                if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                state <= ST_FETCH;
                            end else
                                take_trap(32'd2, instr, pc);
                        end

                        7'b1110011: begin // SYSTEM / CSR
                            if (funct3 == 3'b000) begin
                                if (instr == 32'h0000_0073)       // ECALL
                                    take_trap((priv_mode == 2'b00) ? 32'd8 : 32'd11, 32'd0, pc);
                                else if (instr == 32'h0010_0073)  // EBREAK
                                    take_trap(32'd3, pc, pc);
                                else if (instr == 32'h3020_0073 && priv_mode == 2'b11) begin // MRET
                                    pc <= csr_mepc;
                                    csr_mstatus[3] <= csr_mstatus[7];
                                    csr_mstatus[7] <= 1'b1;
                                    priv_mode <= (ENABLE_U && csr_mstatus[12:11] == 2'b00) ? 2'b00 : 2'b11;
                                    csr_mstatus[12:11] <= ENABLE_U ? 2'b00 : 2'b11;
                                    if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                    state <= ST_FETCH;
                                end else if (instr == 32'h1050_0073) begin // WFI
                                    pc <= pc + 32'd4;
                                    if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                    state <= ST_WFI;
                                end else
                                    take_trap(32'd2, instr, pc);
                            end else begin
                                if (!csr_supported(instr[31:20]) ||
                                    !csr_access_allowed(instr[31:20])) begin
                                    take_trap(32'd2, instr, pc);
                                end else begin
                                    csr_old = csr_read(instr[31:20]);
                                    csr_src = funct3[2] ? {27'd0, rs1_idx} : rs1_val;
                                    case (funct3)
                                        3'b001,3'b101: begin csr_new = csr_src;           csr_do_write = 1'b1; end
                                        3'b010,3'b110: begin csr_new = csr_old | csr_src; csr_do_write = (csr_src != 0); end
                                        3'b011,3'b111: begin csr_new = csr_old & ~csr_src;csr_do_write = (csr_src != 0); end
                                        default: begin csr_new = csr_old; csr_do_write = 1'b0; end
                                    endcase
                                    csr_illegal_write = csr_do_write && !csr_writable(instr[31:20]);
                                    if (funct3 == 3'b100 || funct3 == 3'b000 || csr_illegal_write)
                                        take_trap(32'd2, instr, pc);
                                    else begin
                                        if (rd_idx != 0) regs[rd_idx] <= csr_old;
                                        if (csr_do_write) write_csr(instr[31:20], csr_new);
                                        pc <= pc + 32'd4;
                                        if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                                        state <= ST_FETCH;
                                    end
                                end
                            end
                        end

                        default: take_trap(32'd2, instr, pc);
                    endcase
                end

                ST_MEM_WAIT: begin
                    if (mem_ready) begin
                        mem_valid <= 1'b0;
                        if (pending_is_load && pending_rd != 0) begin
                            case (pending_load_funct3)
                                3'b000: begin // LB
                                    case (pending_addr_low)
                                        2'd0: regs[pending_rd] <= {{24{mem_rdata[7]}},  mem_rdata[7:0]};
                                        2'd1: regs[pending_rd] <= {{24{mem_rdata[15]}}, mem_rdata[15:8]};
                                        2'd2: regs[pending_rd] <= {{24{mem_rdata[23]}}, mem_rdata[23:16]};
                                        default: regs[pending_rd] <= {{24{mem_rdata[31]}}, mem_rdata[31:24]};
                                    endcase
                                end
                                3'b001: begin // LH
                                    regs[pending_rd] <= pending_addr_low[1]
                                        ? {{16{mem_rdata[31]}}, mem_rdata[31:16]}
                                        : {{16{mem_rdata[15]}}, mem_rdata[15:0]};
                                end
                                3'b010: regs[pending_rd] <= mem_rdata; // LW
                                3'b100: begin // LBU
                                    case (pending_addr_low)
                                        2'd0: regs[pending_rd] <= {24'd0, mem_rdata[7:0]};
                                        2'd1: regs[pending_rd] <= {24'd0, mem_rdata[15:8]};
                                        2'd2: regs[pending_rd] <= {24'd0, mem_rdata[23:16]};
                                        default: regs[pending_rd] <= {24'd0, mem_rdata[31:24]};
                                    endcase
                                end
                                3'b101: regs[pending_rd] <= pending_addr_low[1]
                                        ? {16'd0, mem_rdata[31:16]}
                                        : {16'd0, mem_rdata[15:0]};
                                default: regs[pending_rd] <= mem_rdata;
                            endcase
                        end
                        pc <= pc + 32'd4;
                        if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                        state <= ST_FETCH;
                    end
                end

                ST_M_WAIT: begin
                    if (mdu_done_i) begin
                        if (pending_rd != 0)
                            regs[pending_rd] <= mdu_result_i;
                        pc <= pc + 32'd4;
                        if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                        state <= ST_FETCH;
                    end
                end

                ST_A_READ: begin
                    if (mem_ready) begin
                        mem_valid <= 1'b0;
                        if (pending_a_funct5 == 5'b00010) begin // LR.W
                            if (pending_rd != 0)
                                regs[pending_rd] <= mem_rdata;
                            reservation_valid <= 1'b1;
                            reservation_addr <= pending_a_addr[31:2];
                            pc <= pc + 32'd4;
                            if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                            state <= ST_FETCH;
                        end else begin
                            pending_a_old <= mem_rdata;
                            pending_a_new <= amo_result(pending_a_funct5, mem_rdata,
                                                       pending_a_operand);
                            reservation_valid <= 1'b0;
                            state <= ST_A_WRITE_REQ;
                        end
                    end
                end

                ST_A_WRITE_REQ: begin
                    mem_valid <= 1'b1;
                    mem_instr <= 1'b0;
                    mem_addr  <= pending_a_addr;
                    mem_wdata <= pending_a_new;
                    mem_wstrb <= 4'b1111;
                    state <= ST_A_WRITE_WAIT;
                end

                ST_A_WRITE_WAIT: begin
                    if (mem_ready) begin
                        mem_valid <= 1'b0;
                        mem_wstrb <= 4'd0;
                        if (pending_rd != 0)
                            regs[pending_rd] <= (pending_a_funct5 == 5'b00011) ?
                                                32'd0 : pending_a_old;
                        reservation_valid <= 1'b0;
                        pc <= pc + 32'd4;
                        if (ENABLE_COUNTERS) csr_minstret <= csr_minstret + 64'd1;
                        state <= ST_FETCH;
                    end
                end

                ST_WFI: begin
                    // WFI may wake when a locally enabled interrupt becomes pending
                    // even if global MIE is zero. If MIE is one, take it immediately.
                    if (irq_any_enabled) begin
                        if (irq_global_enable) begin
                            if (irq_ext_pending)
                                take_trap(32'h8000_000B, 32'd0, pc);
                            else if (irq_swi_pending)
                                take_trap(32'h8000_0003, 32'd0, pc);
                            else
                                take_trap(32'h8000_0007, 32'd0, pc);
                        end else
                            state <= ST_FETCH;
                    end
                end

                default: state <= ST_FETCH;
            endcase
        end
    end
endmodule
