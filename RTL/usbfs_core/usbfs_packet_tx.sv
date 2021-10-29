`timescale 1ns/1ns

// module usbfs_packet_tx
//    USB Full Speed (12Mbps) device packet sender
// function:
//    pack PID, ADDR, data bytes, and CRC5 or CRC16 to TX packet
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

initial {tp_byte_req, tx_bit, tx_fin} = '0;

function automatic logic [15:0] CRC16(input [15:0] crc, input inbit);
    automatic logic xorbit = crc[15] ^ inbit;
    return {crc[14:0],1'b0} ^ {xorbit,12'b0,xorbit,1'b0,xorbit};
endfunction

reg [ 7:0] pid = '0;
reg [ 3:0] cnt = '0;
reg [15:0] crc16 = '1;
enum logic [2:0] {IDLE, TXPID, TXDATA, TXCRC, TXFIN} status = IDLE;

assign tx_sta = tp_sta;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        {tp_byte_req, tx_bit, tx_fin} <= '0;
        {pid, cnt} <= '0;
        crc16 <= '1;
        status <= IDLE;
    end else begin
        {tp_byte_req, tx_bit, tx_fin} <= '0;
        case(status)
            IDLE   :
                begin
                    pid <= {~tp_pid, tp_pid};
                    cnt <= '0;
                    crc16 <= '1;
                    if(tp_sta)
                        status <= TXPID;
                end 
            TXPID  : 
                if(tx_req) begin
                    tx_bit <= pid[cnt];
                    if(cnt != 4'd7) begin
                        cnt <= cnt + 4'd1;
                    end else begin
                        cnt <= '0;
                        if(pid[1:0] == 2'b11) begin
                            tp_byte_req <= 1'b1;
                            status <= TXDATA;
                        end else
                            status <= TXFIN;
                    end
                end
            TXDATA :
                if(tp_byte_req) begin
                end else if(~tp_fin_n) begin
                    crc16 <= ~crc16;
                    status <= TXCRC;
                end else if(tx_req) begin
                    crc16 <= CRC16(crc16, tp_byte[cnt]);
                    tx_bit <= tp_byte[cnt];
                    if(cnt != 4'd7) begin
                        cnt <= cnt + 4'd1;
                    end else begin
                        cnt <= '0;
                        tp_byte_req <= 1'b1;
                    end
                end
            TXCRC  :
                if(tx_req) begin
                    {tx_bit, crc16} <= {crc16, 1'b1};
                    if(cnt != 4'd15)
                        cnt <= cnt + 4'd1;
                    else
                        status <= TXFIN;
                end
            TXFIN  :
                if(tx_req) begin
                    tx_fin <= 1'b1;
                    status <= IDLE;
                end
            default:
                status <= IDLE;
        endcase
    end

endmodule
