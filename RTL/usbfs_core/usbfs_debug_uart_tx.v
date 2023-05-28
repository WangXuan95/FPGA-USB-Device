
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_debug_uart_tx
// Type    : synthesizable, IP's sub module
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: buffer input data and send them to UART
// UART format: 8 data bits, no parity
//--------------------------------------------------------------------------------------------------------

module usbfs_debug_uart_tx #(
    parameter CLK_DIV = 434,       // UART baud rate = clk freq/CLK_DIV. for example, when clk=50MHz, CLK_DIV=434, then baud=50MHz/434=115200
    parameter ASIZE   = 10         // UART TX buffer size = 2^ASIZE bytes, Set it smaller if your FPGA doesn't have enough BRAM
) (
    input  wire       rstn,
    input  wire       clk,
    // user interface
    input  wire [7:0] tx_data,
    input  wire       tx_en,
    output wire       tx_rdy,
    // uart tx output signal
    output reg        o_uart_tx
);


initial o_uart_tx = 1'b1;


//-------------------------------------------------------------------------------------------------------------------------------------
// send buffer
//-------------------------------------------------------------------------------------------------------------------------------------

reg [7:0] buffer [(1<<ASIZE)-1 : 0];   // may automatically synthesize to BRAM
reg [7:0] rddata;
reg [ASIZE:0] wptr, rptr;

wire full  = (wptr == {~rptr[ASIZE], rptr[ASIZE-1:0]} );
wire empty = (wptr == rptr);

assign tx_rdy = ~full;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        wptr <= 0;
    end else begin
        if (tx_en & ~full)
            wptr <= wptr + 1;
    end

always @ (posedge clk)
    if (tx_en & ~full)
        buffer[wptr[ASIZE-1:0]] <= tx_data;

always @ (posedge clk)
    rddata <= buffer[rptr[ASIZE-1:0]];



//-------------------------------------------------------------------------------------------------------------------------------------
// UART TX
//-------------------------------------------------------------------------------------------------------------------------------------

reg [31:0] cnt = 0;
reg [ 3:0] tx_cnt = 4'h0;
reg [ 7:0] tx_shift = 8'hFF;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        rptr <= 0;
        cnt <= 0;
        tx_cnt <= 4'h0;
        tx_shift <= 8'hFF;
        o_uart_tx <= 1'b1;
    end else begin
        if (cnt < (CLK_DIV-1)) begin
            cnt <= cnt + 1;
        end else begin
            cnt <= 0;
            {tx_shift, o_uart_tx} <= {1'b1, tx_shift};
            if (tx_cnt != 4'h0) begin
                tx_cnt <= tx_cnt - 4'd1;
            end else if (~empty) begin
                rptr <= rptr + 1;
                tx_cnt <= 4'd11;
                tx_shift <= rddata;
                o_uart_tx <= 1'b0;
            end
        end
    end


endmodule
