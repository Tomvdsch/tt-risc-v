`timescale 1ns/1ps
// Behavioral APS6404L subset used by the SoC test.
// Supports recovery/reset plus both persistent-QPI and KianV-style SPI command
// followed by quad address/data. v0.2.29 and later use the latter.
module aps6404_model #(parameter MEM_BYTES=8192)(
    input wire cs_n, input wire sck, inout wire [3:0] dq
);
    reg [7:0] mem[0:MEM_BYTES-1];
    reg qpi_mode;
    reg [3:0] dq_out;
    reg dq_drive;
    assign dq = dq_drive ? dq_out : 4'bz;

    integer serial_bits;
    reg [7:0] serial_shift;
    reg [7:0] command;
    integer quad_cycle;
    reg [3:0] command_hi;
    reg [23:0] address_shift;
    reg [23:0] address;
    reg [3:0] write_hi;
    integer data_nibble;
    integer i;

    initial begin
        qpi_mode=0;
        dq_out=0;
        dq_drive=0;
        serial_bits=0;
        serial_shift=0;
        command=0;
        quad_cycle=0;
        command_hi=0;
        address_shift=0;
        address=0;
        write_hi=0;
        data_nibble=0;
        for(i=0;i<MEM_BYTES;i=i+1)
            mem[i]=0;
    end

    always @(negedge cs_n) begin
        serial_bits=0;
        serial_shift=0;
        command=0;
        quad_cycle=0;
        address_shift=0;
        data_nibble=0;
        dq_drive=0;
    end

    always @(posedge cs_n)
        dq_drive=0;

    always @(posedge sck) if(!cs_n) begin
        if(qpi_mode) begin
            if(quad_cycle==0)
                command_hi<=dq;
            else if(quad_cycle==1) begin
                command<={command_hi,dq};
                if({command_hi,dq}==8'hF5)
                    qpi_mode<=1'b0;
            end else if(quad_cycle>=2 && quad_cycle<=7) begin
                address_shift <= {address_shift[19:0],dq};
                if(quad_cycle==7)
                    address <= {address_shift[19:0],dq};
            end else if(command==8'h38 && quad_cycle>=8) begin
                data_nibble=quad_cycle-8;
                if((data_nibble%2)==0)
                    write_hi<=dq;
                else if(address+(data_nibble/2)<MEM_BYTES)
                    mem[address+(data_nibble/2)] <= {write_hi,dq};
            end
            quad_cycle=quad_cycle+1;
        end else if(serial_bits<8) begin
            serial_shift <= {serial_shift[6:0],dq[0]};
            if(serial_bits==7) begin
                command <= {serial_shift[6:0],dq[0]};
                if({serial_shift[6:0],dq[0]}==8'h35)
                    qpi_mode<=1'b1;
                if({serial_shift[6:0],dq[0]}==8'h99)
                    qpi_mode<=1'b0;
                quad_cycle=0;
            end
            serial_bits=serial_bits+1;
        end else begin
            // SPI command has completed. 0x38 and 0xEB change to four data
            // lines for six address nibbles and then payload/dummy cycles.
            if(quad_cycle<=5) begin
                address_shift <= {address_shift[19:0],dq};
                if(quad_cycle==5)
                    address <= {address_shift[19:0],dq};
            end else if(command==8'h38) begin
                data_nibble=quad_cycle-6;
                if((data_nibble%2)==0)
                    write_hi<=dq;
                else if(address+(data_nibble/2)<MEM_BYTES)
                    mem[address+(data_nibble/2)] <= {write_hi,dq};
            end
            quad_cycle=quad_cycle+1;
        end
    end

    // After the serial command and six quad address cycles, 0xEB has six
    // complete dummy clocks. Present a new data nibble after every subsequent
    // falling edge so it is stable for the master's next rising edge.
    always @(negedge sck) if(!cs_n) begin
        if(!qpi_mode && command==8'hEB && serial_bits>=8 && quad_cycle>=12) begin
            dq_drive<=1'b1;
            data_nibble=quad_cycle-12;
            if(address+(data_nibble/2)<MEM_BYTES) begin
                if((data_nibble%2)==0)
                    dq_out<=mem[address+(data_nibble/2)][7:4];
                else
                    dq_out<=mem[address+(data_nibble/2)][3:0];
            end else begin
                dq_out<=4'hF;
            end
        end else if(qpi_mode && command==8'hEB && quad_cycle>=14) begin
            dq_drive<=1'b1;
            data_nibble=quad_cycle-14;
            if(address+(data_nibble/2)<MEM_BYTES) begin
                if((data_nibble%2)==0)
                    dq_out<=mem[address+(data_nibble/2)][7:4];
                else
                    dq_out<=mem[address+(data_nibble/2)][3:0];
            end else begin
                dq_out<=4'hF;
            end
        end else begin
            dq_drive<=1'b0;
        end
    end
endmodule
