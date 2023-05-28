
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_packet_tx
// Type    : synthesizable, IP's sub module
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: USB Full Speed (12Mbps) device packet sender
//           pack PID, ADDR, data bytes, and CRC5 or CRC16 to TX packet
//--------------------------------------------------------------------------------------------------------

module usbfs_packet_tx (
    input  wire        rstn,
    input  wire        clk,
    // TX packet-level interface (device NEVER send token and special packet)
    input  wire        tp_sta,
    input  wire [ 3:0] tp_pid,         // must valid when and after tp_sta=1
    output reg         tp_byte_req,    // send byte request
    input  wire [ 7:0] tp_byte,        // must be valid at the cycle after tp_byte_req=1
    input  wire        tp_fin_n,
    // TX bit-level signals
    output wire        tx_sta,
    input  wire        tx_req,
    output reg         tx_bit,
    output reg         tx_fin
);



initial tp_byte_req = 1'b0;
initial tx_bit      = 1'b0;
initial tx_fin      = 1'b0;


function  [15:0] CRC16;
    input [15:0] crc;
    input        inbit;
    reg          xorbit;
begin
    xorbit = crc[15] ^ inbit;
    CRC16  = {crc[14:0],1'b0} ^ {xorbit,12'b0,xorbit,1'b0,xorbit};
end
endfunction


reg [ 7:0] pid = 8'h0;
reg [ 3:0] cnt = 4'h0;
reg [15:0] crc16 = 16'hFFFF;

localparam [2:0] S_IDLE   = 3'd0,
                 S_TXPID  = 3'd1,
                 S_TXDATA = 3'd2,
                 S_TXCRC  = 3'd3,
                 S_TXFIN  = 3'd4;
reg [2:0] state = S_IDLE;

assign tx_sta = tp_sta;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        tp_byte_req <= 1'b0;
        tx_bit      <= 1'b0;
        tx_fin      <= 1'b0;
        pid   <= 8'h0;
        cnt   <= 4'h0;
        crc16 <= 16'hFFFF;
        state <= S_IDLE;
    end else begin
        tp_byte_req <= 1'b0;
        tx_bit      <= 1'b0;
        tx_fin      <= 1'b0;
        
        case (state)
            S_IDLE   : begin
                pid   <= {~tp_pid, tp_pid};
                cnt   <= 4'h0;
                crc16 <= 16'hFFFF;
                if (tp_sta)
                    state <= S_TXPID;
            end
            
            S_TXPID  : 
                if (tx_req) begin
                    tx_bit <= pid[cnt];
                    if (cnt != 4'd7) begin
                        cnt <= cnt + 4'd1;
                    end else begin
                        cnt <= 4'h0;
                        if (pid[1:0] == 2'b11) begin
                            tp_byte_req <= 1'b1;
                            state <= S_TXDATA;
                        end else
                            state <= S_TXFIN;
                    end
                end
            
            S_TXDATA :
                if (tp_byte_req) begin
                end else if (~tp_fin_n) begin
                    crc16 <= ~crc16;
                    state <= S_TXCRC;
                end else if (tx_req) begin
                    crc16 <= CRC16(crc16, tp_byte[cnt]);
                    tx_bit <= tp_byte[cnt];
                    if (cnt != 4'd7) begin
                        cnt <= cnt + 4'd1;
                    end else begin
                        cnt <= 4'h0;
                        tp_byte_req <= 1'b1;
                    end
                end
            
            S_TXCRC  :
                if (tx_req) begin
                    {tx_bit, crc16} <= {crc16, 1'b1};
                    if (cnt != 4'd15)
                        cnt <= cnt + 4'd1;
                    else
                        state <= S_TXFIN;
                end
            
            default  : //S_TXFIN  :
                if (tx_req) begin
                    tx_fin <= 1'b1;
                    state <= S_IDLE;
                end
        endcase
    end

endmodule
