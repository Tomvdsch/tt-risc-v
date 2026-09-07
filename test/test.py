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


def b_type(imm, rs2, rs1, funct3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
        ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | \
        (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def csr(csr_number, rs1, funct3, rd):
    return ((csr_number & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 7) << 12) | ((rd & 0x1F) << 7) | 0x73


def cpu_program():
    code = []
    emit = code.append
    emit(i_type(0x400, 0, 0, 1))
    emit(i_type(5, 0, 0, 2))
    emit(i_type(7, 0, 0, 3))

    for funct7, funct3, rd, offset in [
        (0x00, 0, 4, 0x04), (0x20, 0, 5, 0x08), (0x00, 1, 6, 0x0C),
        (0x00, 2, 7, 0x10), (0x00, 3, 8, 0x14), (0x00, 4, 9, 0x18),
        (0x00, 5, 10, 0x1C), (0x00, 6, 11, 0x20), (0x00, 7, 12, 0x24),
    ]:
        emit(r_type(funct7, 3, 2, funct3, rd)); emit(s_type(offset, rd, 1))
    emit(i_type(-8, 0, 0, 13)); emit(i_type(1, 0, 0, 14))
    emit(r_type(0x20, 14, 13, 5, 15)); emit(s_type(0x28, 15, 1))
    emit(i_type(9, 0, 0, 16)); emit(s_type(0x2C, 16, 1))
    emit(i_type(0, 13, 2, 17)); emit(s_type(0x30, 17, 1))
    emit(i_type(0x55, 2, 4, 18)); emit(s_type(0x34, 18, 1))
    emit(i_type(8, 2, 6, 19)); emit(s_type(0x38, 19, 1))
    emit(i_type(4, 3, 7, 20)); emit(s_type(0x3C, 20, 1))

    emit(i_type(-1, 0, 0, 18)); emit(s_type(0x50, 18, 1, 0))
    emit(i_type(0x50, 1, 4, 19, 0x03)); emit(s_type(0x54, 19, 1))
    emit(i_type(0x50, 1, 0, 20, 0x03)); emit(s_type(0x58, 20, 1))
    emit(i_type(0x123, 0, 0, 18)); emit(s_type(0x52, 18, 1, 1))
    emit(i_type(0x52, 1, 5, 21, 0x03)); emit(s_type(0x5C, 21, 1))
    emit(i_type(0x52, 1, 1, 22, 0x03)); emit(s_type(0x60, 22, 1))
    emit(i_type(0x50, 1, 2, 23, 0x03)); emit(s_type(0x64, 23, 1))

    emit(i_type(0, 0, 0, 24)); emit(b_type(8, 2, 2, 0)); emit(i_type(1, 24, 0, 24))
    emit(i_type(2, 24, 0, 24)); emit(s_type(0x68, 24, 1))
    emit(b_type(8, 3, 2, 1)); emit(i_type(4, 24, 0, 24))
    emit(i_type(8, 24, 0, 24)); emit(s_type(0x6C, 24, 1))

    emit(i_type(-7, 0, 0, 16)); emit(i_type(3, 0, 0, 17))
    for funct3, rd, offset in [(0, 18, 0x80), (1, 19, 0x84), (2, 20, 0x88),
                               (3, 21, 0x8C), (4, 22, 0x90), (5, 23, 0x94),
                               (6, 24, 0x98), (7, 25, 0x9C)]:
        emit(r_type(1, 17, 16, funct3, rd))
        emit(s_type(offset, rd, 1))

    emit(csr(0x301, 0, 2, 5)); emit(s_type(0xA0, 5, 1))
    emit(csr(0xC01, 0, 2, 5)); emit(s_type(0xA4, 5, 1))
    emit(csr(0xC81, 0, 2, 5)); emit(s_type(0xA8, 5, 1))
    emit(0x0000100F)
    emit(i_type(0x300, 0, 0, 10)); emit(csr(0x305, 10, 1, 0))
    emit(i_type(0x280, 0, 0, 10)); emit(csr(0x341, 10, 1, 0))
    emit(csr(0x300, 0, 1, 0))
    emit(0x30200073)

    image = {index: instruction for index, instruction in enumerate(code)}
    image[0x280 // 4] = 0x00000073
    image[0x300 // 4] = csr(0x342, 0, 2, 9)
    image[0x304 // 4] = s_type(0xB0, 9, 1)
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
    image[0x33C // 4] = s_type(0xB4, 9, 1)
    image[0x340 // 4] = 0x0000006F
    image[0x360 // 4] = csr(0x342, 0, 2, 9)
    image[0x364 // 4] = s_type(0xBC, 9, 1)
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


def signed32(value):
    return value - (1 << 32) if value & 0x80000000 else value


def mdu_reference(funct3, a, b):
    a &= 0xFFFFFFFF
    b &= 0xFFFFFFFF
    sa = signed32(a)
    sb = signed32(b)
    if funct3 == 0:
        return (a * b) & 0xFFFFFFFF
    if funct3 == 1:
        return ((sa * sb) >> 32) & 0xFFFFFFFF
    if funct3 == 2:
        return ((sa * b) >> 32) & 0xFFFFFFFF
    if funct3 == 3:
        return ((a * b) >> 32) & 0xFFFFFFFF
    if b == 0:
        return 0xFFFFFFFF if funct3 in (4, 5) else a
    if funct3 in (4, 6) and a == 0x80000000 and b == 0xFFFFFFFF:
        return 0x80000000 if funct3 == 4 else 0
    if funct3 in (4, 6):
        quotient = abs(sa) // abs(sb)
        if (sa < 0) != (sb < 0):
            quotient = -quotient
        remainder = sa - quotient * sb
    else:
        quotient = a // b
        remainder = a % b
    return (remainder if funct3 in (6, 7) else quotient) & 0xFFFFFFFF


async def check_mdu(dut, funct3, a, b):
    dut.mdu_test_funct3.value = funct3
    dut.mdu_test_a.value = a
    dut.mdu_test_b.value = b
    dut.mdu_test_start.value = 1
    await RisingEdge(dut.clk)
    dut.mdu_test_start.value = 0
    await Timer(1, unit="ns")
    if not int(dut.mdu_test_done.value):
        for _ in range(40):
            await RisingEdge(dut.clk)
            if int(dut.mdu_test_done.value):
                break
        else:
            raise AssertionError(f"MDU operation {funct3} timed out")
    expected = mdu_reference(funct3, a, b)
    actual = int(dut.mdu_test_result.value)
    assert actual == expected, (
        f"MDU operation {funct3}, a=0x{a:08X}, b=0x{b:08X}: "
        f"expected 0x{expected:08X}, got 0x{actual:08X}"
    )


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
        i_type(8, 3, 2, 5, 0x03), s_type(4, 5, 1),
        i_type(0x5A, 0, 0, 6), s_type(8, 6, 1, 0),
        i_type(8, 1, 4, 7, 0x03), s_type(12, 7, 1),
        0x08000213, 0x0041A623, 0x0000100F, 0x00008067,
    ]
    for word_index, word in enumerate(flash_program):
        for byte_index in range(4):
            dut.flash.mem[word_index * 4 + byte_index].value = (word >> (8 * byte_index)) & 0xFF

    await reset_design(dut)

    for _ in range(200000):
        await RisingEdge(dut.clk)
        psram_init = dut.user_project.u_soc.psram_init_done.value
        if psram_init.is_resolvable and int(psram_init):
            break
    else:
        raise AssertionError(
            "PSRAM initialization did not complete; "
            f"controller_state={dut.user_project.u_soc.u_psram.state.value} "
            f"wait_count={dut.user_project.u_soc.u_psram.wait_count.value} "
            f"ram_cs={dut.uio_bus.value[0]} ram_sck={dut.uio_bus.value[1]}"
        )

    for _ in range(100000):
        await RisingEdge(dut.clk)
        boot_done = dut.user_project.u_soc.debug_boot_done.value
        first_byte = dut.psram.mem[0].value
        pc = dut.user_project.u_soc.debug_pc.value
        if (boot_done.is_resolvable and first_byte.is_resolvable and pc.is_resolvable and
                int(boot_done) and int(first_byte) == 0x6F and int(pc) == 0x80000000):
            break
    else:
        raise AssertionError(
            "flash-to-PSRAM integration did not complete; "
            f"boot_status={dut.user_project.u_soc.debug_boot_status.value} "
            f"pc={pc} cpu_mem_valid={dut.user_project.u_soc.cpu_mem_valid.value} "
            f"cpu_mem_instr={dut.user_project.u_soc.cpu_mem_instr.value} "
            f"cpu_mem_addr={dut.user_project.u_soc.cpu_mem_addr.value} "
            f"icache_state={dut.user_project.u_soc.u_icache.state.value} "
            f"flash_state={dut.user_project.u_soc.u_flash.state.value} "
            f"psram_state={dut.user_project.u_soc.u_psram.state.value} "
            f"data_bridge_state={dut.user_project.u_soc.data_ram_state.value} "
            f"flash_cs={dut.uo_out.value[0]} ram_cs={dut.uio_bus.value[0]} "
            f"ram_byte0={first_byte}"
        )

    feature_word = sum(int(dut.psram.mem[4 + index].value) << (8 * index)
                       for index in range(4))
    assert feature_word == 0x10
    assert int(dut.psram.mem[8].value) == 0x5A
    partial_store_echo = sum(int(dut.psram.mem[12 + index].value) << (8 * index)
                             for index in range(4))
    assert partial_store_echo == 0x5A

    for _ in range(8000):
        await RisingEdge(dut.clk)
        if int(dut.cpu_ram[(0x400 + 0xB0) // 4].value) == 11:
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
        if int(dut.cpu_ram[(0x400 + 0xBC) // 4].value) == 0x80000003:
            dut.cpu_irq_software.value = 0
            break
    else:
        raise AssertionError("WFI did not wake and trap on machine software interrupt")
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.cpu_ram[(0x400 + 0xB4) // 4].value) == 0x5A:
            break
    else:
        raise AssertionError("MRET did not resume after machine software interrupt")

    expected = {
        0x04: 12, 0x08: 0xFFFFFFFE, 0x0C: 640, 0x10: 1,
        0x14: 1, 0x18: 2, 0x1C: 0, 0x20: 7, 0x24: 5,
        0x28: 0xFFFFFFFC, 0x2C: 9, 0x30: 1, 0x34: 0x50,
        0x38: 13, 0x3C: 4, 0x54: 0xFF, 0x58: 0xFFFFFFFF,
        0x5C: 0x123, 0x60: 0x123, 0x64: 0x012300FF,
        0x68: 2, 0x6C: 10,
        0x80: 0xFFFFFFEB, 0x84: 0xFFFFFFFF, 0x88: 0xFFFFFFFF,
        0x8C: 2, 0x90: 0xFFFFFFFE, 0x94: 0x55555553,
        0x98: 0xFFFFFFFF, 0x9C: 0, 0xA4: 0x55667788,
        0xA8: 0x11223344, 0xB0: 11,
    }
    for offset, value in expected.items():
        actual = int(dut.cpu_ram[(0x400 + offset) // 4].value)
        assert actual == value, f"CPU signature +0x{offset:02X}: expected 0x{value:08X}, got 0x{actual:08X}"
    misa = int(dut.cpu_ram[(0x400 + 0xA0) // 4].value)
    assert misa == 0x40001100

    mdu_vectors = [
        (0xFFFFFFF9, 3), (0x80000000, 0xFFFFFFFF),
        (0x7FFFFFFF, 0x80000001), (0x12345678, 0x9ABCDEF0),
        (0, 0), (0xFFFFFFFF, 1),
    ]
    for funct3 in range(8):
        for a, b in mdu_vectors:
            await check_mdu(dut, funct3, a, b)

    await bus_write(dut, "clint", 0x0000, 1)
    assert int(dut.clint_msip.value) == 1
    await bus_write(dut, "clint", 0x0000, 0)
    assert int(dut.clint_msip.value) == 0
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
    assert await bus_read(dut, "plic", 0x200004) == 1
    await bus_write(dut, "plic", 0x200004, 1)
    await bus_write(dut, "plic", 0x000020, 3)
    await bus_write(dut, "plic", 0x002000, 0x100)
    await bus_write(dut, "plic", 0x200000, 2)
    dut.plic_sources.value = 0x80
    await ClockCycles(dut.clk, 3)
    assert int(dut.plic_irq.value) == 1
    assert await bus_read(dut, "plic", 0x200004) == 8
    dut.plic_sources.value = 0
    await bus_write(dut, "plic", 0x200004, 8)

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
    dut.gpio_ui.value = 4
    await ClockCycles(dut.clk, 2)
    await bus_write(dut, "gpio", 0x24, 0x0004)
    dut.gpio_ui.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(dut.gpio_irq.value) == 1
    await bus_write(dut, "gpio", 0x28, 0x0004)

    await bus_write(dut, "uart", 0x0C, 4)
    await bus_write(dut, "uart", 0x08, 1)
    await bus_write(dut, "uart", 0x00, 0xA5)
    assert int(dut.uart_tx.value) == 0
    for bit in range(8):
        await ClockCycles(dut.clk, 4)
        await Timer(1, unit="ns")
        assert int(dut.uart_tx.value) == ((0xA5 >> bit) & 1)
    await ClockCycles(dut.clk, 4)
    await Timer(1, unit="ns")
    assert int(dut.uart_tx.value) == 1
    await ClockCycles(dut.clk, 4)
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

    await bus_write(dut, "spi", 0x10, 1)
    for mode in range(8):
        await bus_write(dut, "spi", 0x08, 0x88 | mode)
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
    await bus_write(dut, "i2c", 0x0C, 0x80)
    await bus_write(dut, "i2c", 0x0C, 0x07)
    for _ in range(300):
        await RisingEdge(dut.clk)
        if int(dut.i2c_irq.value):
            break
    assert int(dut.i2c_irq.value) == 1
    assert await bus_read(dut, "i2c", 0x08) == 0

    await bus_write(dut, "pwm", 0x00, 8)
    for channel in range(5):
        await bus_write(dut, "pwm", 0x10 + channel * 4, channel + 1)
    await bus_write(dut, "pwm", 0x04, 0x3F)
    observed_pwm = [set() for _ in range(5)]
    for _ in range(20):
        await RisingEdge(dut.clk)
        value = int(dut.pwm_outputs.value)
        for channel in range(5):
            observed_pwm[channel].add((value >> channel) & 1)
    assert all(samples == {0, 1} for samples in observed_pwm)

    await bus_write(dut, "timer", 0x00, 4)
    await bus_write(dut, "timer", 0x08, 7)
    await ClockCycles(dut.clk, 8)
    assert int(dut.timer_irq.value) == 1
    await bus_write(dut, "timer", 0x0C, 1)
    await ClockCycles(dut.clk, 6)
    assert int(dut.timer_irq.value) == 1

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
