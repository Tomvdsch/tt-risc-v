module tiny32_soc #(
    parameter ENABLE_M = 1,
    parameter ENABLE_A = 0,
    parameter ENABLE_U = 0,
    parameter ENABLE_COUNTERS = 0,
    parameter ICACHE_WORDS = 1,
    parameter SYS_CLK_HZ = 25000000,
    parameter WATCHDOG_RESETS_CPU = 1,
    parameter RESET_VECTOR = 32'h2000_0000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    output wire [31:0] debug_pc,
    output wire        debug_boot_done,
    output wire [7:0]  debug_boot_status
);

    // The CPU executes stage 1 directly from the read-only flash window.
    wire flash_cs_n, flash_mosi, flash_sck;
    wire flash_ctrl_ready, flash_ctrl_done, flash_ctrl_rd_valid;
    wire [31:0] flash_ctrl_rd_data;
    reg flash_ctrl_req;
    reg [22:0] flash_ctrl_addr;
    reg [3:0] flash_ctrl_words;
    reg runtime_flash_req;
    reg [22:0] runtime_flash_addr;
    reg [1:0] runtime_flash_state;
    reg runtime_flash_ready;
    reg flash_owner; // 0 shared instruction cache, 1 CPU data
    localparam RF_IDLE=2'd0, RF_REQ=2'd1, RF_WAIT=2'd2, RF_DROP=2'd3;

    spi_flash u_flash (
        .clk(clk), .rst_n(rst_n),
        .req_valid(flash_ctrl_req), .req_addr(flash_ctrl_addr), .req_words(flash_ctrl_words),
        .req_ready(flash_ctrl_ready),
        .req_done(flash_ctrl_done), .rd_valid(flash_ctrl_rd_valid), .rd_data(flash_ctrl_rd_data),
        .flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi), .flash_sck(flash_sck),
        .flash_miso(ui_in[0])
    );

    wire ram_cs_n, ram_sck;
    wire [3:0] ram_dq_o, ram_dq_oe;
    wire [3:0] ram_dq_i = uio_in[5:2];
    wire psram_init_done;
    wire psram_ctrl_ready, psram_ctrl_done, psram_ctrl_rd_valid;
    wire [31:0] psram_ctrl_rd_data;
    reg psram_ctrl_req, psram_ctrl_write;
    reg [22:0] psram_ctrl_addr;
    reg [31:0] psram_ctrl_wdata;
    reg [3:0] psram_ctrl_wstrb;
    reg [3:0] psram_ctrl_words;
    reg psram_owner; // 0 instruction cache, 1 CPU data

    wire ic_mem_req;
    wire [31:0] ic_mem_addr;
    wire [3:0] ic_mem_words;
    wire ic_mem_is_flash = (ic_mem_addr[31:23] == 9'b001000000);
    reg ic_owner_flash;
    wire ic_mem_rd_valid = ic_owner_flash ?
        (flash_ctrl_rd_valid && flash_owner == 1'b0) :
        (psram_ctrl_rd_valid && psram_owner == 1'b0);
    wire ic_mem_done = ic_owner_flash ?
        (flash_ctrl_done && flash_owner == 1'b0) :
        (psram_ctrl_done && psram_owner == 1'b0);

    reg data_ram_req;
    reg data_ram_write;
    reg [22:0] data_ram_addr;
    reg [31:0] data_ram_wdata;
    reg [3:0] data_ram_wstrb;
    reg [3:0] data_ram_state;
    reg [31:0] data_ram_rdata;
    reg [31:0] data_ram_merged_data;
    reg data_ram_ready;
    localparam DR_IDLE=4'd0, DR_REQ=4'd1, DR_WAIT=4'd2,
               DR_RMW_READ_REQ=4'd3, DR_RMW_READ_WAIT=4'd4,
               DR_RMW_WRITE_REQ=4'd5, DR_RMW_WRITE_WAIT=4'd6,
               DR_DROP=4'd7;
    wire data_ram_rd_valid = psram_ctrl_rd_valid && (psram_owner == 1'b1);
    wire data_ram_done     = psram_ctrl_done     && (psram_owner == 1'b1);
    wire runtime_flash_done     = flash_ctrl_done     && (flash_owner == 1'b1);

    // Selection-aware acceptance signals. A controller can be idle while a
    // different master owns its request mux, so raw controller readiness is
    // not sufficient for a waiting master to advance.
    wire flash_ic_selected      = ic_mem_req && ic_mem_is_flash;
    wire flash_runtime_selected = !flash_ic_selected && runtime_flash_req;
    wire psram_data_selected    = data_ram_req;
    wire psram_ic_selected      = !data_ram_req && ic_mem_req && !ic_mem_is_flash;
    wire runtime_flash_accept   = flash_runtime_selected && flash_ctrl_ready;
    wire data_ram_accept        = psram_data_selected && psram_ctrl_ready;
    wire ic_mem_ready = ic_mem_is_flash ?
        (flash_ic_selected && flash_ctrl_ready) :
        (psram_ic_selected && psram_ctrl_ready);

    qspi_psram #(
        .POWERUP_WAIT_CYCLES(SYS_CLK_HZ/5000),
        .RESET_WAIT_CYCLES(SYS_CLK_HZ/200),
        // Two full system clocks with CS high exceed the APS6404L minimum
        // deselect time at the configured tapeout clock without crippling traffic.
        .INTEROP_WAIT_CYCLES(2)
    ) u_psram (
        .clk(clk), .rst_n(rst_n),
        .req_valid(psram_ctrl_req), .req_write(psram_ctrl_write),
        .req_addr(psram_ctrl_addr), .req_wdata(psram_ctrl_wdata),
        .req_wstrb(psram_ctrl_wstrb), .req_words(psram_ctrl_words),
        .req_ready(psram_ctrl_ready),
        .req_done(psram_ctrl_done), .rd_valid(psram_ctrl_rd_valid),
        .rd_data(psram_ctrl_rd_data), .init_done(psram_init_done),
        .ram_cs_n(ram_cs_n), .ram_sck(ram_sck), .ram_dq_o(ram_dq_o),
        .ram_dq_oe(ram_dq_oe), .ram_dq_i(ram_dq_i)
    );

    reg [7:0] boot_status_reg;
    assign debug_boot_done = (boot_status_reg == 8'h80);
    assign debug_boot_status = boot_status_reg;

    wire cpu_mem_valid, cpu_mem_instr;
    wire [31:0] cpu_mem_addr, cpu_mem_wdata;
    wire [3:0] cpu_mem_wstrb;
    reg cpu_mem_ready;
    reg [31:0] cpu_mem_rdata;
    wire cpu_fence_i;

    wire irq_software, irq_timer, irq_external;
    wire [63:0] mtime_value;
    wire watchdog_reset_pulse;
    // Hardware initializes PSRAM; flash stage 1 parses and copies the image.
    wire runtime_rst_n = rst_n & psram_init_done;
    wire cpu_rst_n = runtime_rst_n & ~(WATCHDOG_RESETS_CPU ? watchdog_reset_pulse : 1'b0);

    rv32_core #(.ENABLE_M(ENABLE_M), .ENABLE_A(ENABLE_A), .ENABLE_U(ENABLE_U),
                .ENABLE_COUNTERS(ENABLE_COUNTERS)) u_cpu (
        .clk(clk), .rst_n(cpu_rst_n), .reset_vector(RESET_VECTOR),
        .irq_software(irq_software), .irq_timer(irq_timer), .irq_external(irq_external),
        .time_value(mtime_value),
        .mem_valid(cpu_mem_valid), .mem_instr(cpu_mem_instr), .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata), .mem_wstrb(cpu_mem_wstrb),
        .mem_ready(cpu_mem_ready), .mem_rdata(cpu_mem_rdata),
        .fence_i(cpu_fence_i), .debug_pc(debug_pc)
    );

    wire sel_ram   = (cpu_mem_addr[31:23] == 9'b100000000); // 0x80000000..0x807fffff
    wire sel_clint = (cpu_mem_addr[31:16] == 16'h0200);
    wire sel_plic  = (cpu_mem_addr[31:22] == 10'b0000110000); // 0x0C000000..0x0C3FFFFF
    wire sel_periph= (cpu_mem_addr[31:20] == 12'h100);
    wire sel_flash = (cpu_mem_addr[31:23] == 9'b001000000); // 0x20000000..0x207fffff

    wire ic_cpu_ready;
    wire [31:0] ic_cpu_rdata;
    // RISC-V software must execute FENCE.I after modifying executable memory.
    // Do not flush on every data store: that would destroy the benefit of the
    // tiny cache for normal stack/data traffic.
    wire ic_invalidate = cpu_fence_i;
    icache #(.LINE_WORDS(ICACHE_WORDS)) u_icache (
        .clk(clk), .rst_n(cpu_rst_n), .invalidate(ic_invalidate),
        .cpu_valid(cpu_mem_valid && cpu_mem_instr && (sel_ram || sel_flash)), .cpu_addr(cpu_mem_addr),
        .cpu_ready(ic_cpu_ready), .cpu_rdata(ic_cpu_rdata),
        .ram_req(ic_mem_req), .ram_addr(ic_mem_addr), .ram_words(ic_mem_words),
        .ram_ready(ic_mem_ready),
        .ram_rd_valid(ic_mem_rd_valid),
        .ram_rd_data(ic_owner_flash ? flash_ctrl_rd_data : psram_ctrl_rd_data),
        .ram_done(ic_mem_done)
    );

    // Partial PSRAM stores use an aligned read-modify-write transaction.
    always @(*) begin
        data_ram_merged_data = data_ram_rdata;
        if(data_ram_wstrb[0])
            data_ram_merged_data[7:0] = data_ram_wdata[7:0];
        if(data_ram_wstrb[1])
            data_ram_merged_data[15:8] = data_ram_wdata[15:8];
        if(data_ram_wstrb[2])
            data_ram_merged_data[23:16] = data_ram_wdata[23:16];
        if(data_ram_wstrb[3])
            data_ram_merged_data[31:24] = data_ram_wdata[31:24];
    end

    // CPU byte and halfword extraction occurs after an aligned PSRAM read.
    always @(posedge clk or negedge cpu_rst_n) begin
        if(!cpu_rst_n) begin
            data_ram_req<=1'b0; data_ram_write<=1'b0; data_ram_addr<=0;
            data_ram_wdata<=0; data_ram_wstrb<=0; data_ram_state<=DR_IDLE;
            data_ram_rdata<=0; data_ram_ready<=1'b0;
        end else begin
            data_ram_ready<=1'b0;
            if(data_ram_rd_valid) data_ram_rdata<=psram_ctrl_rd_data;
            case(data_ram_state)
                DR_IDLE: begin
                    data_ram_req <= 1'b0;
                    if(cpu_mem_valid && !cpu_mem_instr && sel_ram) begin
                        if((|cpu_mem_wstrb) && cpu_mem_wstrb != 4'b1111) begin
                            data_ram_write <= 1'b0;
                            data_ram_addr <= {cpu_mem_addr[22:2],2'b00};
                            data_ram_wdata <= cpu_mem_wdata;
                            data_ram_wstrb <= cpu_mem_wstrb;
                            data_ram_state <= DR_RMW_READ_REQ;
                        end else begin
                            data_ram_write <= |cpu_mem_wstrb;
                            data_ram_addr <= {cpu_mem_addr[22:2],2'b00};
                            data_ram_wdata <= cpu_mem_wdata;
                            data_ram_wstrb <= cpu_mem_wstrb;
                            data_ram_state <= DR_REQ;
                        end
                    end
                end
                DR_REQ: begin
                    data_ram_req <= 1'b1;
                    if(data_ram_accept) begin
                        data_ram_req <= 1'b0;
                        data_ram_state <= DR_WAIT;
                    end
                end
                DR_WAIT: if(data_ram_done) begin
                    data_ram_ready<=1'b1;
                    data_ram_state<=DR_DROP;
                end
                DR_RMW_READ_REQ: begin
                    data_ram_req <= 1'b1;
                    if(data_ram_accept) begin
                        data_ram_req <= 1'b0;
                        data_ram_state <= DR_RMW_READ_WAIT;
                    end
                end
                DR_RMW_READ_WAIT: if(data_ram_done) begin
                    data_ram_write <= 1'b1;
                    data_ram_wdata <= data_ram_merged_data;
                    data_ram_wstrb <= 4'b1111;
                    data_ram_state <= DR_RMW_WRITE_REQ;
                end
                DR_RMW_WRITE_REQ: begin
                    data_ram_req <= 1'b1;
                    if(data_ram_accept) begin
                        data_ram_req <= 1'b0;
                        data_ram_state <= DR_RMW_WRITE_WAIT;
                    end
                end
                DR_RMW_WRITE_WAIT: if(data_ram_done) begin
                    data_ram_ready <= 1'b1;
                    data_ram_state <= DR_DROP;
                end
                DR_DROP: begin
                    data_ram_req <= 1'b0;
                    if(!cpu_mem_valid) data_ram_state<=DR_IDLE;
                end
                default: begin
                    data_ram_req <= 1'b0;
                    data_ram_state<=DR_IDLE;
                end
            endcase
        end
    end

    // Runtime flash read bridge. Stores to the flash window are ignored but
    // acknowledged; programming/erase is intentionally omitted from v0.2 RTL.
    always @(posedge clk or negedge cpu_rst_n) begin
        if(!cpu_rst_n) begin
            runtime_flash_req<=1'b0; runtime_flash_addr<=0; runtime_flash_state<=RF_IDLE;
            runtime_flash_ready<=1'b0;
        end else begin
            runtime_flash_ready<=1'b0;
            case(runtime_flash_state)
                RF_IDLE: begin
                    runtime_flash_req<=1'b0;
                    if(cpu_mem_valid && !cpu_mem_instr && sel_flash) begin
                        if(|cpu_mem_wstrb) begin
                            runtime_flash_ready<=1'b1;
                            runtime_flash_state<=RF_DROP;
                        end else begin
                            runtime_flash_addr<= {cpu_mem_addr[22:2],2'b00};
                            runtime_flash_state<=RF_REQ;
                        end
                    end
                end
                RF_REQ: begin
                    runtime_flash_req<=1'b1;
                    if(runtime_flash_accept) begin
                        runtime_flash_req<=1'b0;
                        runtime_flash_state<=RF_WAIT;
                    end
                end
                RF_WAIT: if(runtime_flash_done) begin
                    runtime_flash_ready<=1'b1;
                    runtime_flash_state<=RF_DROP;
                end
                RF_DROP: begin
                    runtime_flash_req<=1'b0;
                    if(!cpu_mem_valid) runtime_flash_state<=RF_IDLE;
                end
                default: begin
                    runtime_flash_req<=1'b0;
                    runtime_flash_state<=RF_IDLE;
                end
            endcase
        end
    end

    // Controller arbitration. CPU data receives priority so the write half of
    // a partial-store read-modify-write sequence cannot be displaced by an
    // instruction-cache refill. The explicit mux keeps ownership unambiguous.
    always @(*) begin
        flash_ctrl_req   = 1'b0;
        flash_ctrl_addr  = 23'd0;
        flash_ctrl_words = 4'd1;
        if(ic_mem_req && ic_mem_is_flash) begin
            flash_ctrl_req   = 1'b1;
            flash_ctrl_addr  = ic_mem_addr[22:0];
            flash_ctrl_words = ic_mem_words;
        end else if(runtime_flash_req) begin
            flash_ctrl_req   = 1'b1;
            flash_ctrl_addr  = runtime_flash_addr;
            flash_ctrl_words = 4'd1;
        end

        psram_ctrl_req   = 1'b0;
        psram_ctrl_write = 1'b0;
        psram_ctrl_addr  = 23'd0;
        psram_ctrl_wdata = 32'd0;
        psram_ctrl_wstrb = 4'd0;
        psram_ctrl_words = 4'd1;
        if(data_ram_req) begin
            psram_ctrl_req   = 1'b1;
            psram_ctrl_write = data_ram_write;
            psram_ctrl_addr  = data_ram_addr;
            psram_ctrl_wdata = data_ram_wdata;
            psram_ctrl_wstrb = data_ram_wstrb;
        end else if(ic_mem_req && !ic_mem_is_flash) begin
            psram_ctrl_req   = 1'b1;
            psram_ctrl_write = 1'b0;
            psram_ctrl_addr  = ic_mem_addr[22:0];
            psram_ctrl_words = ic_mem_words;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            psram_owner<=1'b0;
            flash_owner<=1'b0;
            ic_owner_flash<=1'b0;
        end else begin
            if(ic_mem_req && ic_mem_ready)
                ic_owner_flash <= ic_mem_is_flash;
            if(flash_ctrl_req && flash_ctrl_ready) begin
                if(flash_ic_selected) flash_owner<=1'b0;
                else flash_owner<=1'b1;
            end
            if(psram_ctrl_req && psram_ctrl_ready) begin
                if(psram_data_selected) psram_owner<=1'b1;
                else psram_owner<=1'b0;
            end
        end
    end

    wire clint_valid = cpu_mem_valid && sel_clint;
    wire plic_valid  = cpu_mem_valid && sel_plic;

    wire [31:0] clint_rdata;
    clint u_clint(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(clint_valid),
        .bus_addr(cpu_mem_addr[15:0]),.bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),
        .bus_rdata(clint_rdata),.irq_software(irq_software),.irq_timer(irq_timer),.mtime_value(mtime_value));

    wire [7:0] plic_sources;
    wire [31:0] plic_rdata;
    plic u_plic(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(plic_valid),.bus_addr(cpu_mem_addr[21:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(plic_rdata),
        .irq_sources(plic_sources),.irq_external(irq_external));

    wire page_sys   = sel_periph && cpu_mem_addr[19:12]==8'h00;
    wire page_gpio  = sel_periph && cpu_mem_addr[19:12]==8'h01;
    wire page_uart  = sel_periph && cpu_mem_addr[19:12]==8'h02;
    wire page_spi   = sel_periph && cpu_mem_addr[19:12]==8'h03;
    wire page_i2c   = sel_periph && cpu_mem_addr[19:12]==8'h04;
    wire page_pwm   = sel_periph && cpu_mem_addr[19:12]==8'h05;
    wire page_timers= sel_periph && cpu_mem_addr[19:12]==8'h06;
    wire page_wdog  = sel_periph && cpu_mem_addr[19:12]==8'h07;

    // Stage-1 reports progress here. Before the CPU is released, 0x01 means
    // that the hardware is waiting for PSRAM; 0x02 means flash execution has
    // begun. 0x80 is success and 0xE1..0xEF are software boot failures.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            boot_status_reg <= 8'h01;
        else if(!psram_init_done)
            boot_status_reg <= 8'h01;
        else if(WATCHDOG_RESETS_CPU && watchdog_reset_pulse)
            boot_status_reg <= 8'h02;
        else begin
            if(boot_status_reg == 8'h01)
                boot_status_reg <= 8'h02;
            if(cpu_mem_valid && page_sys && |cpu_mem_wstrb &&
               cpu_mem_addr[7:0] == 8'h0C && cpu_mem_wstrb[0])
                boot_status_reg <= cpu_mem_wdata[7:0];
        end
    end

    wire [31:0] gpio_rdata, uart_rdata, spi_rdata, i2c_rdata, pwm_rdata, timer0_rdata, timer1_rdata, wdog_rdata;
    wire gpio_irq, uart_irq, spi_irq, i2c_irq, timer0_irq, timer1_irq, wdog_irq;
    wire uart_tx, spi_mosi, spi_sck, spi_cs_n;
    wire [4:0] pwm_out_i;
    wire i2c_scl_drive_low, i2c_sda_drive_low;

    gpio_pinmux u_gpio(
        .clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && page_gpio),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(gpio_rdata),
        .ui_in(ui_in),.uio_in(uio_in),.uo_out(uo_out),.uio_out(uio_out),.uio_oe(uio_oe),
        .flash_cs_n(flash_cs_n),.flash_mosi(flash_mosi),.flash_sck(flash_sck),
        .ram_cs_n(ram_cs_n),.ram_sck(ram_sck),.ram_dq_o(ram_dq_o),.ram_dq_oe(ram_dq_oe),
        .uart_tx(uart_tx),.spi_cs_n(spi_cs_n),.spi_mosi(spi_mosi),.spi_sck(spi_sck),.pwm_out(pwm_out_i),
        .i2c_scl_drive_low(i2c_scl_drive_low),.i2c_sda_drive_low(i2c_sda_drive_low),.gpio_irq(gpio_irq));

    uart #(.DEFAULT_DIV(SYS_CLK_HZ/115200)) u_uart(
        .clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && page_uart),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(uart_rdata),
        .uart_rx(ui_in[7]),.uart_tx(uart_tx),.irq(uart_irq));

    spi_master u_spi(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && page_spi),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(spi_rdata),
        .spi_miso(ui_in[1]),.spi_mosi(spi_mosi),.spi_sck(spi_sck),.spi_cs_n(spi_cs_n),.irq(spi_irq));

    i2c_master #(.DEFAULT_PRESCALE(SYS_CLK_HZ/200000)) u_i2c(
        .clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && page_i2c),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(i2c_rdata),
        .scl_in(uio_in[6]),.sda_in(uio_in[7]),.scl_drive_low(i2c_scl_drive_low),
        .sda_drive_low(i2c_sda_drive_low),.irq(i2c_irq));

    pwm u_pwm(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && page_pwm),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(pwm_rdata),.pwm_out(pwm_out_i));

    wire timer0_sel = page_timers && cpu_mem_addr[11:8]==4'h0;
    wire timer1_sel = page_timers && cpu_mem_addr[11:8]==4'h1;
    timer32 u_timer0(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && timer0_sel),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(timer0_rdata),.irq(timer0_irq));
    timer32 u_timer1(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && timer1_sel),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(timer1_rdata),.irq(timer1_irq));

    watchdog u_wdog(.clk(clk),.rst_n(runtime_rst_n),.bus_valid(cpu_mem_valid && page_wdog),.bus_addr(cpu_mem_addr[7:0]),
        .bus_wdata(cpu_mem_wdata),.bus_wstrb(cpu_mem_wstrb),.bus_rdata(wdog_rdata),
        .irq(wdog_irq),.reset_pulse(watchdog_reset_pulse));

    assign plic_sources = {1'd0,wdog_irq,timer1_irq,timer0_irq,gpio_irq,i2c_irq,spi_irq,uart_irq};

    // System information block: intentionally mostly read-only.
    localparam [3:0] ICACHE_WORDS_INFO = ICACHE_WORDS;
    reg [31:0] sys_rdata;
    always @(*) begin
        case(cpu_mem_addr[7:0])
            8'h00: sys_rdata = 32'h5332_3354; // "T32S" marker
            8'h04: sys_rdata = SYS_CLK_HZ;
            8'h08: sys_rdata = {16'd0,6'd0,(ENABLE_U ? 1'b1:1'b0),
                                (ENABLE_A ? 1'b1:1'b0),ICACHE_WORDS_INFO,
                                2'd0,(ENABLE_COUNTERS ? 1'b1:1'b0),
                                (ENABLE_M ? 1'b1:1'b0)};
            8'h0C: sys_rdata = {24'd0,boot_status_reg};
            8'h10: sys_rdata = RESET_VECTOR;
            8'h14: sys_rdata = 32'h0080_0000;
            8'h18: sys_rdata = 32'h0080_0000;
            default: sys_rdata = 32'd0;
        endcase
    end

    reg [31:0] periph_rdata;
    always @(*) begin
        if(page_sys) periph_rdata=sys_rdata;
        else if(page_gpio) periph_rdata=gpio_rdata;
        else if(page_uart) periph_rdata=uart_rdata;
        else if(page_spi) periph_rdata=spi_rdata;
        else if(page_i2c) periph_rdata=i2c_rdata;
        else if(page_pwm) periph_rdata=pwm_rdata;
        else if(timer0_sel) periph_rdata=timer0_rdata;
        else if(timer1_sel) periph_rdata=timer1_rdata;
        else if(page_wdog) periph_rdata=wdog_rdata;
        else periph_rdata=32'd0;
    end

    // Final CPU read-data/ready mux. MMIO responds in one bus cycle. Serial
    // memories respond only when their bridges complete.
    always @(*) begin
        cpu_mem_ready = 1'b0;
        cpu_mem_rdata = 32'd0;
        if(cpu_mem_valid) begin
            if(sel_ram) begin
                if(cpu_mem_instr) begin cpu_mem_ready=ic_cpu_ready; cpu_mem_rdata=ic_cpu_rdata; end
                else begin cpu_mem_ready=data_ram_ready; cpu_mem_rdata=data_ram_rdata; end
            end else if(sel_clint) begin
                cpu_mem_ready=1'b1; cpu_mem_rdata=clint_rdata;
            end else if(sel_plic) begin
                cpu_mem_ready=1'b1; cpu_mem_rdata=plic_rdata;
            end else if(sel_periph) begin
                cpu_mem_ready=1'b1; cpu_mem_rdata=periph_rdata;
            end else if(sel_flash) begin
                if(cpu_mem_instr) begin cpu_mem_ready=ic_cpu_ready; cpu_mem_rdata=ic_cpu_rdata; end
                else begin cpu_mem_ready=runtime_flash_ready; cpu_mem_rdata=flash_ctrl_rd_data; end
            end else begin
                // Unmapped accesses complete rather than deadlocking. A future
                // revision can add a bus-fault input to raise access exceptions.
                cpu_mem_ready=1'b1; cpu_mem_rdata=32'hDEAD_BEEF;
            end
        end
    end
endmodule
