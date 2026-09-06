/*
 * Copyright (c) 2026 Tomvdsch
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns/1ps

module tb;
    reg clk;
    reg rst_n;
    reg ena;
    reg [7:0] ui_drive;
    wire [7:0] ui_in;
    wire [7:0] uo_out;
    wire [7:0] uio_bus;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    wire flash_miso;

`ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
`endif

    assign ui_in = {ui_drive[7:1], flash_miso};

    genvar pin;
    generate
        for (pin = 0; pin < 8; pin = pin + 1) begin : uio_resolve
            assign uio_bus[pin] = uio_oe[pin] ? uio_out[pin] : 1'bz;
        end
    endgenerate
    pullup(uio_bus[6]);
    pullup(uio_bus[7]);

    tt_um_tomvdsch_tiny32_soc user_project (
`ifdef GL_TEST
        .VPWR(VPWR),
        .VGND(VGND),
`endif
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_bus),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(ena),
        .clk(clk),
        .rst_n(rst_n)
    );

    w25q64_model #(.MEM_BYTES(4096)) flash (
        .cs_n(uo_out[0]), .sck(uo_out[2]), .mosi(uo_out[1]), .miso(flash_miso)
    );

    aps6404_model #(.MEM_BYTES(8192)) psram (
        .cs_n(uio_bus[0]), .sck(uio_bus[1]), .dq(uio_bus[5:2])
    );

`ifndef GL_TEST
    reg unit_rst_n;

    wire cpu_mem_valid;
    wire cpu_mem_instr;
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire [3:0] cpu_mem_wstrb;
    wire [31:0] cpu_mem_rdata;
    wire cpu_fence_i;
    wire [31:0] cpu_debug_pc;
    reg cpu_irq_software;
    reg cpu_irq_timer;
    reg cpu_irq_external;
    reg [31:0] cpu_ram [0:511];

    assign cpu_mem_rdata = cpu_ram[cpu_mem_addr[10:2]];

    always @(posedge clk) begin
        if (cpu_mem_valid && cpu_mem_wstrb[0]) cpu_ram[cpu_mem_addr[10:2]][7:0] <= cpu_mem_wdata[7:0];
        if (cpu_mem_valid && cpu_mem_wstrb[1]) cpu_ram[cpu_mem_addr[10:2]][15:8] <= cpu_mem_wdata[15:8];
        if (cpu_mem_valid && cpu_mem_wstrb[2]) cpu_ram[cpu_mem_addr[10:2]][23:16] <= cpu_mem_wdata[23:16];
        if (cpu_mem_valid && cpu_mem_wstrb[3]) cpu_ram[cpu_mem_addr[10:2]][31:24] <= cpu_mem_wdata[31:24];
    end

    rv32_core #(.ENABLE_M(1), .ENABLE_A(1), .ENABLE_U(1), .ENABLE_COUNTERS(1)) cpu_unit (
        .clk(clk), .rst_n(unit_rst_n), .reset_vector(32'd0),
        .irq_software(cpu_irq_software), .irq_timer(cpu_irq_timer),
        .irq_external(cpu_irq_external),
        .time_value(64'd0), .mem_valid(cpu_mem_valid), .mem_instr(cpu_mem_instr),
        .mem_addr(cpu_mem_addr), .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(cpu_mem_wstrb), .mem_ready(cpu_mem_valid),
        .mem_rdata(cpu_mem_rdata), .fence_i(cpu_fence_i), .debug_pc(cpu_debug_pc)
    );

    reg clint_valid;
    reg [15:0] clint_addr;
    reg [31:0] clint_wdata;
    reg [3:0] clint_wstrb;
    wire [31:0] clint_rdata;
    wire clint_msip;
    wire clint_mtip;
    wire [63:0] clint_mtime;
    clint clint_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(clint_valid),
        .bus_addr(clint_addr), .bus_wdata(clint_wdata), .bus_wstrb(clint_wstrb),
        .bus_rdata(clint_rdata), .irq_software(clint_msip),
        .irq_timer(clint_mtip), .mtime_value(clint_mtime)
    );

    reg plic_valid;
    reg [21:0] plic_addr;
    reg [31:0] plic_wdata;
    reg [3:0] plic_wstrb;
    reg [15:0] plic_sources;
    wire [31:0] plic_rdata;
    wire plic_irq;
    plic plic_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(plic_valid),
        .bus_addr(plic_addr), .bus_wdata(plic_wdata), .bus_wstrb(plic_wstrb),
        .bus_rdata(plic_rdata), .irq_sources(plic_sources), .irq_external(plic_irq)
    );

    reg gpio_valid;
    reg [7:0] gpio_addr;
    reg [31:0] gpio_wdata;
    reg [3:0] gpio_wstrb;
    reg [7:0] gpio_ui;
    reg [7:0] gpio_uio_in;
    wire [31:0] gpio_rdata;
    wire [7:0] gpio_uo;
    wire [7:0] gpio_uio_out;
    wire [7:0] gpio_uio_oe;
    wire gpio_irq;
    gpio_pinmux gpio_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(gpio_valid),
        .bus_addr(gpio_addr), .bus_wdata(gpio_wdata), .bus_wstrb(gpio_wstrb),
        .bus_rdata(gpio_rdata), .ui_in(gpio_ui), .uio_in(gpio_uio_in),
        .uo_out(gpio_uo), .uio_out(gpio_uio_out), .uio_oe(gpio_uio_oe),
        .flash_cs_n(1'b1), .flash_mosi(1'b0), .flash_sck(1'b0),
        .ram_cs_n(1'b1), .ram_sck(1'b0), .ram_dq_o(4'd0), .ram_dq_oe(4'd0),
        .uart_tx(1'b1), .spi_cs_n(1'b1), .spi_mosi(1'b0), .spi_sck(1'b0),
        .pwm_out(5'd0), .i2c_scl_drive_low(1'b0), .i2c_sda_drive_low(1'b0),
        .gpio_irq(gpio_irq)
    );

    reg uart_valid;
    reg [7:0] uart_addr;
    reg [31:0] uart_wdata;
    reg [3:0] uart_wstrb;
    reg uart_rx;
    wire [31:0] uart_rdata;
    wire uart_tx;
    wire uart_irq;
    uart #(.DEFAULT_DIV(4)) uart_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(uart_valid),
        .bus_addr(uart_addr), .bus_wdata(uart_wdata), .bus_wstrb(uart_wstrb),
        .bus_rdata(uart_rdata), .uart_rx(uart_rx), .uart_tx(uart_tx), .irq(uart_irq)
    );

    reg spi_valid;
    reg [7:0] spi_addr;
    reg [31:0] spi_wdata;
    reg [3:0] spi_wstrb;
    wire [31:0] spi_rdata;
    wire spi_mosi;
    wire spi_sck;
    wire spi_cs_n;
    wire spi_irq;
    spi_master #(.DEFAULT_DIV(2)) spi_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(spi_valid),
        .bus_addr(spi_addr), .bus_wdata(spi_wdata), .bus_wstrb(spi_wstrb),
        .bus_rdata(spi_rdata), .spi_miso(spi_mosi), .spi_mosi(spi_mosi),
        .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .irq(spi_irq)
    );

    reg i2c_valid;
    reg [7:0] i2c_addr;
    reg [31:0] i2c_wdata;
    reg [3:0] i2c_wstrb;
    reg i2c_scl_in;
    reg i2c_sda_in;
    wire [31:0] i2c_rdata;
    wire i2c_scl_low;
    wire i2c_sda_low;
    wire i2c_irq;
    i2c_master #(.DEFAULT_PRESCALE(2)) i2c_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(i2c_valid),
        .bus_addr(i2c_addr), .bus_wdata(i2c_wdata), .bus_wstrb(i2c_wstrb),
        .bus_rdata(i2c_rdata), .scl_in(i2c_scl_in), .sda_in(i2c_sda_in),
        .scl_drive_low(i2c_scl_low), .sda_drive_low(i2c_sda_low), .irq(i2c_irq)
    );

    reg pwm_valid;
    reg [7:0] pwm_addr;
    reg [31:0] pwm_wdata;
    reg [3:0] pwm_wstrb;
    wire [31:0] pwm_rdata;
    wire [4:0] pwm_outputs;
    pwm pwm_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(pwm_valid),
        .bus_addr(pwm_addr), .bus_wdata(pwm_wdata), .bus_wstrb(pwm_wstrb),
        .bus_rdata(pwm_rdata), .pwm_out(pwm_outputs)
    );

    reg timer_valid;
    reg [7:0] timer_addr;
    reg [31:0] timer_wdata;
    reg [3:0] timer_wstrb;
    wire [31:0] timer_rdata;
    wire timer_irq;
    timer32 timer_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(timer_valid),
        .bus_addr(timer_addr), .bus_wdata(timer_wdata), .bus_wstrb(timer_wstrb),
        .bus_rdata(timer_rdata), .irq(timer_irq)
    );

    reg watchdog_valid;
    reg [7:0] watchdog_addr;
    reg [31:0] watchdog_wdata;
    reg [3:0] watchdog_wstrb;
    wire [31:0] watchdog_rdata;
    wire watchdog_irq;
    wire watchdog_reset;
    watchdog watchdog_unit (
        .clk(clk), .rst_n(unit_rst_n), .bus_valid(watchdog_valid),
        .bus_addr(watchdog_addr), .bus_wdata(watchdog_wdata),
        .bus_wstrb(watchdog_wstrb), .bus_rdata(watchdog_rdata),
        .irq(watchdog_irq), .reset_pulse(watchdog_reset)
    );
`endif

    initial begin
        $dumpfile("tb.fst");
        $dumpvars(0, tb);
        clk = 1'b0;
        rst_n = 1'b0;
        ena = 1'b1;
        ui_drive = 8'hFF;
`ifndef GL_TEST
        unit_rst_n = 1'b0;
        cpu_irq_software = 0; cpu_irq_timer = 0; cpu_irq_external = 0;
        clint_valid = 0; clint_addr = 0; clint_wdata = 0; clint_wstrb = 0;
        plic_valid = 0; plic_addr = 0; plic_wdata = 0; plic_wstrb = 0; plic_sources = 0;
        gpio_valid = 0; gpio_addr = 0; gpio_wdata = 0; gpio_wstrb = 0; gpio_ui = 0; gpio_uio_in = 0;
        uart_valid = 0; uart_addr = 0; uart_wdata = 0; uart_wstrb = 0; uart_rx = 1;
        spi_valid = 0; spi_addr = 0; spi_wdata = 0; spi_wstrb = 0;
        i2c_valid = 0; i2c_addr = 0; i2c_wdata = 0; i2c_wstrb = 0; i2c_scl_in = 1; i2c_sda_in = 0;
        pwm_valid = 0; pwm_addr = 0; pwm_wdata = 0; pwm_wstrb = 0;
        timer_valid = 0; timer_addr = 0; timer_wdata = 0; timer_wstrb = 0;
        watchdog_valid = 0; watchdog_addr = 0; watchdog_wdata = 0; watchdog_wstrb = 0;
`endif
    end
endmodule

`default_nettype wire
