/*
 * Copyright (c) 2026 Tomvdsch
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_tomvdsch_tiny32_soc (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    tiny32_soc #(
        .ENABLE_M(0),
        .ENABLE_A(0),
        .ENABLE_U(0),
        .ENABLE_COUNTERS(0),
        .ENABLE_SPI(1),
        .ENABLE_I2C(1),
        .ENABLE_TIMER1(1),
        .ENABLE_WATCHDOG(0),
        .PWM_CHANNELS(3),
        .ICACHE_WORDS(1),
        .SYS_CLK_HZ(25000000)
    ) u_soc (
        .clk(clk),
        .rst_n(rst_n),
        .ui_in(ui_in),
        .uo_out(uo_out),
        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .debug_pc(),
        .debug_boot_done(),
        .debug_boot_status()
    );

    wire _unused = &{ena, 1'b0};

endmodule

`default_nettype wire
