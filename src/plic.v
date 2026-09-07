// Single-hart, 8-source, machine-mode PLIC-compatible controller.
module plic (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire [21:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_wstrb,
    output reg  [31:0] bus_rdata,
    input  wire [7:0] irq_sources,
    output wire        irq_external
);
    // Avoid the identifier "priority": Quartus treats it as a newer
    // SystemVerilog keyword even when compiling this file as Verilog-2001.
    reg [2:0] source_priority [1:8];
    reg [7:0] pending;
    reg [7:0] in_service;
    reg [7:0] enable;
    reg [2:0] threshold;

    integer k_comb;
    integer k_seq;
    reg [3:0] best_id;
    reg [2:0] best_prio;
    wire [5:0] priority_index = bus_addr[7:2];

    always @(*) begin
        best_id   = 4'd0;
        best_prio = 3'd0;
        // Lowest source ID wins equal-priority ties.
        for (k_comb = 1; k_comb <= 8; k_comb = k_comb + 1) begin
            if (pending[k_comb-1] && enable[k_comb-1] &&
                source_priority[k_comb] > threshold &&
                source_priority[k_comb] > best_prio) begin
                best_id   = k_comb[3:0];
                best_prio = source_priority[k_comb];
            end
        end
    end

    assign irq_external = (best_id != 0);

    always @(*) begin
        bus_rdata = 32'd0;
        if (bus_addr >= 22'h000004 && bus_addr <= 22'h000020 && bus_addr[1:0] == 0) begin
            if (priority_index >= 1 && priority_index <= 8)
                bus_rdata = {29'd0,source_priority[priority_index]};
        end else begin
            case (bus_addr)
                22'h001000: bus_rdata = {23'd0,pending,1'b0};
                22'h002000: bus_rdata = {23'd0,enable,1'b0};
                22'h200000: bus_rdata = {29'd0,threshold};
                22'h200004: bus_rdata = {28'd0,best_id};
                default: bus_rdata = 32'd0;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending   <= 8'd0;
            in_service<= 8'd0;
            enable    <= 8'd0;
            threshold <= 3'd0;
            for (k_seq = 1; k_seq <= 8; k_seq = k_seq + 1)
                source_priority[k_seq] <= 3'd0;
        end else begin
            // Level gateways do not forward a source again while software is
            // servicing the interrupt it previously claimed.
            pending <= pending | (irq_sources & ~in_service);

            if (bus_valid && |bus_wstrb) begin
                if (bus_addr >= 22'h000004 && bus_addr <= 22'h000020 && bus_addr[1:0] == 0) begin
                    if (priority_index >= 1 && priority_index <= 8 && bus_wstrb[0])
                        source_priority[priority_index] <= bus_wdata[2:0];
                end else begin
                    case (bus_addr)
                        22'h002000: begin
                            if (bus_wstrb[0]) enable[6:0] <= bus_wdata[7:1];
                            if (bus_wstrb[1]) enable[7] <= bus_wdata[8];
                        end
                        22'h200000: if (bus_wstrb[0]) threshold <= bus_wdata[2:0];
                        22'h200004: begin
                            // Completion only releases a source that is
                            // currently in service. If its level remains high,
                            // the gateway may make it pending again next cycle.
                            if (bus_wdata[3:0] >= 1 && bus_wdata[3:0] <= 8)
                                in_service[bus_wdata[3:0]-1] <= 1'b0;
                        end
                        default: ;
                    endcase
                end
            end

            // Claim consumes pending state and marks the gateway in service.
            if (bus_valid && !(|bus_wstrb) &&
                bus_addr == 22'h200004 && best_id != 0) begin
                pending[best_id-1] <= 1'b0;
                in_service[best_id-1] <= 1'b1;
            end
        end
    end
endmodule
