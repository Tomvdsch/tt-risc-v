`timescale 1ns/1ps
// Behavioral subset of W25Q64: only command 0x03 normal read is modeled.
module w25q64_model #(parameter MEM_BYTES=4096)(
    input wire cs_n,input wire sck,input wire mosi,output reg miso
);
    reg [7:0] mem[0:MEM_BYTES-1];
    reg [7:0] cmd_shift;
    reg [23:0] addr_shift;
    reg [23:0] address;
    integer bit_count;
    integer data_bit;
    reg [7:0] command;
    integer i;
    initial begin
        miso=0; command=0; bit_count=0; data_bit=0; address=0; cmd_shift=0; addr_shift=0;
        for(i=0;i<MEM_BYTES;i=i+1) mem[i]=8'hFF;
    end
    always @(negedge cs_n) begin bit_count=0; data_bit=0; cmd_shift=0; addr_shift=0; miso=0; end
    always @(posedge sck) if(!cs_n) begin
        if(bit_count<8) begin
            cmd_shift <= {cmd_shift[6:0],mosi};
            if(bit_count==7) command <= {cmd_shift[6:0],mosi};
        end else if(bit_count<32) begin
            addr_shift <= {addr_shift[22:0],mosi};
            if(bit_count==31) address <= {addr_shift[22:0],mosi};
        end
        bit_count=bit_count+1;
    end
    always @(negedge sck) if(!cs_n && bit_count>=32 && command==8'h03) begin
        if(address + (data_bit/8) < MEM_BYTES)
            miso <= mem[address + (data_bit/8)][7-(data_bit%8)];
        else miso <= 1'b1;
        data_bit=data_bit+1;
    end
endmodule
