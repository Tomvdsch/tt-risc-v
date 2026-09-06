# SPDX-FileCopyrightText: 2026 Tomvdsch
# SPDX-License-Identifier: Apache-2.0

SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src

PROJECT_SOURCES = project.v tiny32_soc.v rv32_core.v rv32_mdu.v \
	qspi_psram.v spi_flash.v icache.v clint.v plic.v gpio_pinmux.v \
	uart.v spi_master.v i2c_master.v pwm.v timer32.v watchdog.v

ifneq ($(GATES),yes)
SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
else
SIM_BUILD = sim_build/gl
COMPILE_ARGS += -DGL_TEST -DFUNCTIONAL -DUSE_POWER_PINS -DSIM
COMPILE_ARGS += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
endif

COMPILE_ARGS += -I$(SRC_DIR)
VERILOG_SOURCES += $(PWD)/w25q64_model.v $(PWD)/aps6404_model.v $(PWD)/tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test

include $(shell cocotb-config --makefiles)/Makefile.sim
