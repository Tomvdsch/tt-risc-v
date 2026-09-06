# SPDX-FileCopyrightText: 2026 Tomvdsch
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer


def r_type(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((rd & 0x1F) << 7) | opcode


def i_type(imm, rs1, funct3, rd, opcode=0x13):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((rd & 0x1F) << 7) | opcode


def s_type(imm, rs2, rs1, funct3=2, opcode=0x23):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((imm & 0x1F) << 7) | opcode


def csr(csr_number, rs1, funct3, rd):
    return ((csr_number & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((rd & 0x1F) << 7) | 0x73


def amo(funct5, rs2, rs1, rd):
    return ((funct5 & 0x1F) << 27) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | (2 << 12) | ((rd & 0x1F) << 7) | 0x2F


def cpu_program():
    code = []
    emit = code.append
    emit(i_type(0x400, 0, 0, 1))
    emit(i_type(5, 0, 0, 2))
    emit(s_type(0, 2, 1))
    emit(i_type(7, 0, 0, 3))

    emit(amo(0x00, 3, 1, 4)); emit(s_type(0x04, 4, 1))
    emit(amo(0x01, 3, 1, 5)); emit(s_type(0x08, 5, 1))
    emit(i_type(3, 0, 0, 3))
    emit(amo(0x04, 3, 1, 6)); emit(s_type(0x0C, 6, 1))
    emit(i_type(6, 0, 0, 3))
    emit(amo(0x0C, 3, 1, 7)); emit(s_type(0x10, 7, 1))
    emit(i_type(8, 0, 0, 3))
    emit(amo(0x08, 3, 1, 8)); emit(s_type(0x14, 8, 1))
    emit(i_type(-1, 0, 0, 3))
    emit(amo(0x10, 3, 1, 9)); emit(s_type(0x18, 9, 1))
    emit(i_type(2, 0, 0, 3))
    emit(amo(0x14, 3, 1, 10)); emit(s_type(0x1C, 10, 1))
    emit(i_type(1, 0, 0, 3))
    emit(amo(0x18, 3, 1, 11)); emit(s_type(0x20, 11, 1))
    emit(i_type(-1, 0, 0, 3))
    emit(amo(0x1C, 3, 1, 12)); emit(s_type(0x24, 12, 1))
    emit(amo(0x02, 0, 1, 13)); emit(s_type(0x28, 13, 1))
    emit(i_type(1, 13, 0, 13))
    emit(amo(0x03, 13, 1, 14)); emit(s_type(0x2C, 14, 1))
    emit(amo(0x03, 13, 1, 15)); emit(s_type(0x30, 15, 1))

    emit(i_type(-7, 0, 0, 16))
    emit(i_type(3, 0, 0, 17))
    for funct3, rd, offset in [(0, 18, 0x40), (1, 19, 0x44), (2, 20, 0x48), (3, 21, 0x4C),
                               (4, 22, 0x50), (5, 23, 0x54), (6, 24, 0x58), (7, 25, 0x5C)]:
        emit(r_type(1, 17, 16, funct3, rd))
        emit(s_type(offset, rd, 1))

    emit(csr(0x301, 0, 2, 5)); emit(s_type(0x60, 5, 1))
    emit(csr(0xC00, 0, 2, 5)); emit(s_type(0x64, 5, 1))
    emit(0x0000100F)
    emit(i_type(0x300, 0, 0, 10)); emit(csr(0x305, 10, 1, 0))
    emit(i_type(0x280, 0, 0, 10)); emit(csr(0x341, 10, 1, 0))
    emit(csr(0x300, 0, 1, 0))
    emit(0x30200073)

    image = {index: instruction for index, instruction in enumerate(code)}
    image[0x280 // 4] = 0x00000073
    image[0x300 // 4] = csr(0x342, 0, 2, 9)
    image[0x304 // 4] = s_type(0x70, 9, 1)
    image[0x308 // 4] = 0x00002537
    image[0x30C // 4] = i_type(-0x800, 10, 0, 10)
    image[0x310 // 4] = csr(0x300, 10, 1, 0)
    image[0x314 // 4] = i_type(0x320, 0, 0, 10)
    image[0x318 // 4] = csr(0x341, 10, 1, 0)
    image[0x31C // 4] = 0x30200073
    image[0x320 // 4] = i_type(0x360, 0, 0, 10)
    image[0x324 // 4] = csr(0x305, 10, 1, 0)
    image[0x328 // 4] = i_type(8, 0, 0, 10)
    image[0x32C // 4] = csr(0x304, 10, 1, 0)
    image[0x330 // 4] = csr(0x300, 8, 6, 0)
    image[0x334 // 4] = 0x10500073
    image[0x338 // 4] = i_type(0x5A, 0, 0, 9)
    image[0x33C // 4] = s_type(0x74, 9, 1)
    image[0x340 // 4] = 0x0000006F
    image[0x360 // 4] = csr(0x342, 0, 2, 9)
    image[0x364 // 4] = s_type(0x7C, 9, 1)
    image[0x368 // 4] = 0x30200073
    return image


async def bus_write(dut, name, address, value, strobes=0xF):
    getattr(dut, f"{name}_addr").value = address
    getattr(dut, f"{name}_wdata").value = value
    getattr(dut, f"{name}_wstrb").value = strobes
    getattr(dut, f"{name}_valid").value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    getattr(dut, f"{name}_valid").value = 0
    getattr(dut, f"{name}_wstrb").value = 0


async def bus_read(dut, name, address):
    getattr(dut, f"{name}_addr").value = address
    getattr(dut, f"{name}_wstrb").value = 0
    getattr(dut, f"{name}_valid").value = 1
    await Timer(1, unit="ns")
    value = int(getattr(dut, f"{name}_rdata").value)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    getattr(dut, f"{name}_valid").value = 0
    return value


async def reset_design(dut):
    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.ui_drive.value = 0xFF
    if os.getenv("GATES") != "yes":
        dut.unit_rst_n.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n.value = 1
    if os.getenv("GATES") != "yes":
        dut.unit_rst_n.value = 1
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_tiny32_soc(dut):
    cocotb.start_soon(Clock(dut.clk, 31.25, unit="ns").start())

    if os.getenv("GATES") == "yes":
        await reset_design(dut)
        await ClockCycles(dut.clk, 32)
        assert dut.uo_out.value.is_resolvable
        assert dut.uio_out.value.is_resolvable
        assert dut.uio_oe.value.is_resolvable
        return

    for index in range(512):
        dut.cpu_ram[index].value = 0
    for index, instruction in cpu_program().items():
        dut.cpu_ram[index].value = instruction

    flash_program = [
        0x800000B7, 0x06F00113, 0x0020A023, 0x100001B7,
        0x08000213, 0x0041A623, 0x0000100F, 0x00008067,
    ]
    for word_index, word in enumerate(flash_program):
        for byte_index in range(4):
            dut.flash.mem[word_index * 4 + byte_index].value = (word >> (8 * byte_index)) & 0xFF

    await reset_design(dut)

    for _ in range(250000):
        await RisingEdge(dut.clk)
        if int(dut.user_project.u_soc.debug_boot_done.value) and int(dut.psram.mem[0].value) == 0x6F:
            break
    else:
        raise AssertionError("flash execution, PSRAM write, cache refill, and jump did not complete")

    for _ in range(8000):
        await RisingEdge(dut.clk)
        if int(dut.cpu_ram[(0x400 + 0x70) // 4].value) == 8:
            break
    else:
        raise AssertionError(f"CPU directed program timed out at PC 0x{int(dut.cpu_debug_pc.value):08X}")

    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.cpu_debug_pc.value) == 0x338:
            break
    else:
        raise AssertionError("CPU did not enter WFI")
    await ClockCycles(dut.clk, 8)
    assert int(dut.cpu_debug_pc.value) == 0x338
    dut.cpu_irq_software.value = 1
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.cpu_ram[(0x400 + 0x7C) // 4].value) == 0x80000003:
            dut.cpu_irq_software.value = 0
            break
    else:
        raise AssertionError("WFI did not wake and trap on machine software interrupt")
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.cpu_ram[(0x400 + 0x74) // 4].value) == 0x5A:
            break
    else:
        raise AssertionError("MRET did not resume after machine software interrupt")

    expected = {
        0x04: 5, 0x08: 12, 0x0C: 7, 0x10: 4, 0x14: 4,
        0x18: 12, 0x1C: 0xFFFFFFFF, 0x20: 2, 0x24: 1,
        0x28: 0xFFFFFFFF, 0x2C: 0, 0x30: 1,
        0x40: 0xFFFFFFEB, 0x44: 0xFFFFFFFF, 0x48: 0xFFFFFFFF,
        0x4C: 2, 0x50: 0xFFFFFFFE, 0x54: 0x55555553,
        0x58: 0xFFFFFFFF, 0x5C: 0, 0x70: 8,
    }
    for offset, value in expected.items():
        actual = int(dut.cpu_ram[(0x400 + offset) // 4].value)
        assert actual == value, f"CPU signature +0x{offset:02X}: expected 0x{value:08X}, got 0x{actual:08X}"
    misa = int(dut.cpu_ram[(0x400 + 0x60) // 4].value)
    assert misa & 0x40101101 == 0x40101101
    assert int(dut.cpu_ram[(0x400 + 0x64) // 4].value) != 0

    await bus_write(dut, "clint", 0x0000, 1)
    assert int(dut.clint_msip.value) == 1
    now = int(dut.clint_mtime.value)
    await bus_write(dut, "clint", 0x4000, (now + 8) & 0xFFFFFFFF)
    await bus_write(dut, "clint", 0x4004, (now + 8) >> 32)
    await ClockCycles(dut.clk, 12)
    assert int(dut.clint_mtip.value) == 1

    await bus_write(dut, "plic", 0x000004, 1)
    await bus_write(dut, "plic", 0x002000, 2)
    dut.plic_sources.value = 1
    await ClockCycles(dut.clk, 3)
    assert int(dut.plic_irq.value) == 1
    assert await bus_read(dut, "plic", 0x200004) == 1
    await ClockCycles(dut.clk, 3)
    assert int(dut.plic_irq.value) == 0
    await bus_write(dut, "plic", 0x200004, 1)
    await ClockCycles(dut.clk, 3)
    assert int(dut.plic_irq.value) == 1
    dut.plic_sources.value = 0

    await bus_write(dut, "gpio", 0x14, 0)
    await bus_write(dut, "gpio", 0x04, 0xA8)
    assert int(dut.gpio_uo.value) & 0xF8 == 0xA8
    await bus_write(dut, "gpio", 0x20, 0x0002)
    dut.gpio_ui.value = 0
    await ClockCycles(dut.clk, 2)
    dut.gpio_ui.value = 2
    await ClockCycles(dut.clk, 2)
    assert int(dut.gpio_irq.value) == 1
    await bus_write(dut, "gpio", 0x28, 0x0002)

    await bus_write(dut, "uart", 0x0C, 4)
    await bus_write(dut, "uart", 0x08, 1)
    await bus_write(dut, "uart", 0x00, 0xA5)
    await ClockCycles(dut.clk, 45)
    assert await bus_read(dut, "uart", 0x04) & 1
    dut.uart_rx.value = 0
    await ClockCycles(dut.clk, 4)
    for bit in range(8):
        dut.uart_rx.value = (0x3C >> bit) & 1
        await ClockCycles(dut.clk, 4)
    dut.uart_rx.value = 1
    await ClockCycles(dut.clk, 8)
    assert int(dut.uart_irq.value) == 1
    assert await bus_read(dut, "uart", 0x00) == 0x3C

    await bus_write(dut, "spi", 0x08, 0x08)
    await bus_write(dut, "spi", 0x10, 1)
    await bus_write(dut, "spi", 0x00, 0xA6)
    await ClockCycles(dut.clk, 40)
    assert await bus_read(dut, "spi", 0x00) == 0xA6
    assert int(dut.spi_irq.value) == 1

    await bus_write(dut, "i2c", 0x00, 2)
    await bus_write(dut, "i2c", 0x04, 3)
    await bus_write(dut, "i2c", 0x08, 0xA5)
    await bus_write(dut, "i2c", 0x0C, 0x0B)
    saw_i2c_activity = False
    for _ in range(300):
        await RisingEdge(dut.clk)
        saw_i2c_activity |= bool(int(dut.i2c_scl_low.value) or int(dut.i2c_sda_low.value))
        if int(dut.i2c_irq.value):
            break
    assert saw_i2c_activity and int(dut.i2c_irq.value)

    await bus_write(dut, "pwm", 0x00, 8)
    await bus_write(dut, "pwm", 0x10, 4)
    await bus_write(dut, "pwm", 0x04, 3)
    observed_pwm = set()
    for _ in range(20):
        await RisingEdge(dut.clk)
        observed_pwm.add(int(dut.pwm_outputs.value) & 1)
    assert observed_pwm == {0, 1}

    await bus_write(dut, "timer", 0x00, 4)
    await bus_write(dut, "timer", 0x08, 7)
    await ClockCycles(dut.clk, 8)
    assert int(dut.timer_irq.value) == 1
    await bus_write(dut, "timer", 0x0C, 1)

    await bus_write(dut, "watchdog", 0x00, 4)
    await bus_write(dut, "watchdog", 0x08, 3)
    await ClockCycles(dut.clk, 8)
    assert int(dut.watchdog_irq.value) == 1
    await bus_write(dut, "watchdog", 0x0C, 0x51F15EED)
    assert int(dut.watchdog_irq.value) == 0
    await bus_write(dut, "watchdog", 0x08, 7)
    saw_reset = False
    for _ in range(8):
        await RisingEdge(dut.clk)
        saw_reset |= bool(int(dut.watchdog_reset.value))
    assert saw_reset
