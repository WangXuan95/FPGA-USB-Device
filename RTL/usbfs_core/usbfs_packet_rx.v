
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_packet_rx
// Type    : synthesizable, IP's sub module
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: USB Full Speed (12Mbps) device packet receiver and parser
//           extract PID, ADDR, and data bytes from RX packet, check and report CRC5 and CRC16 status
//--------------------------------------------------------------------------------------------------------

module usbfs_packet_rx (
    input  wire        rstn,
    input  wire        clk,
    // RX bit-level signals
    input  wire        rx_sta,
    input  wire        rx_ena,
    input  wire        rx_bit,
    input  wire        rx_fin,
    // RX packet-level signals
    output reg  [ 3:0] rp_pid,
    output reg  [10:0] rp_addr,
    output reg         rp_byte_en,
    output reg  [ 7:0] rp_byte,
    output reg         rp_fin,
    output reg         rp_okay
);



initial rp_pid     = 4'h0;
initial rp_addr    = 11'h0;
initial rp_byte_en = 1'b0;
initial rp_byte    = 8'h0;
initial rp_fin     = 1'b0;
initial rp_okay    = 1'b0;


function  [4:0] CRC5;
    input [4:0] crc;
    input       inbit;
    reg         xorbit;
begin
    xorbit = crc[4] ^ inbit;
    CRC5   = {crc[3:0],1'b0} ^ {2'b0,xorbit,1'b0,xorbit};
end
endfunction


function  [15:0] CRC16;
    input [15:0] crc;
    input        inbit;
    reg          xorbit;
begin
    xorbit = crc[15] ^ inbit;
    CRC16  = {crc[14:0],1'b0} ^ {xorbit,12'b0,xorbit,1'b0,xorbit};
end
endfunction


reg        rx_valid   = 1'b0;
reg [ 1:0] rx_bytecnt = 2'b0;
reg [ 4:0] rx_bcnt    = 5'h0;
reg [ 2:0] rx_cnt     = 3'h0;
reg [23:0] rx_shift   = 24'h0;
reg [ 4:0] rx_crc5    = 5'h1F;
reg [15:0] rx_crc16   = 16'hFFFF;

wire[23:0] rx_shift_next = {rx_bit, rx_shift[23:1]};


always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        rp_pid     <= 4'h0;
        rp_addr    <= 11'h0;
        rp_byte_en <= 1'b0;
        rp_byte    <= 8'h0;
        
        rx_valid   <= 1'b0;
        rx_bytecnt <= 2'b0;
        rx_bcnt    <= 5'h0;
        rx_cnt     <= 3'h0;
        rx_shift   <= 24'h0;
        
        rx_crc5    <= 5'h1F;
        rx_crc16   <= 16'hFFFF;
    end else begin
        rp_byte_en <= 1'b0;
        
        if (rx_sta) begin
            rp_pid     <= 4'h0;
            rx_valid   <= 1'b0;
            rx_bytecnt <= 2'b0;
            rx_bcnt    <= 5'h0;
            rx_cnt     <= 3'h0;
            rx_shift   <= 24'h0;
            rx_crc5    <= 5'h1F;
            rx_crc16   <= 16'hFFFF;
        end else if (rx_ena) begin
            rx_cnt   <= rx_cnt + 3'd1;
            rx_shift <= rx_shift_next;
            
            if (rx_bytecnt != 2'b0) begin
                if (rx_bcnt >= 5'd5)
                    rx_crc5  <= CRC5(rx_crc5, rx_shift_next[18]);
                if (rx_bcnt >= 5'd16)
                    rx_crc16 <= CRC16(rx_crc16, rx_shift_next[7]);
                if (rx_bcnt != 5'd31)
                    rx_bcnt <= rx_bcnt + 5'd1;
            end
            
            if (rx_cnt == 3'd7) begin
                if (rx_bytecnt == 2'd0) begin
                    if ( & (rx_shift_next[23:20] ^ rx_shift_next[19:16]) ) begin   // PID valid
                        rx_valid <= 1'b1;
                        rp_pid <= rx_shift_next[19:16];
                    end
                end
                if (rx_bytecnt == 2'd2 && rx_valid && rp_pid[1:0] == 2'b01)
                    rp_addr <= rx_shift_next[18:8];
                if (rx_bytecnt == 2'd3 && rx_valid && rp_pid[1:0] == 2'b11) begin
                    rp_byte_en <= 1'b1;
                    rp_byte <= rx_shift_next[7:0];
                end
                if (rx_bytecnt != 2'd3)
                    rx_bytecnt <= rx_bytecnt + 2'd1;
            end
        end
    end


always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        rp_fin  <= 1'b0;
        rp_okay <= 1'b0;
    end else begin
        rp_fin <= rx_fin;
        case (rp_pid[1:0])
            2'b01  :               // token packet     //
                rp_okay <= rx_valid && (~{rx_crc5[0],rx_crc5[1],rx_crc5[2],rx_crc5[3],rx_crc5[4]} == rx_shift[23:19]);
            2'b10  :               // handshake packet //
                rp_okay <= rx_valid;
            2'b11  :               // data packet      //
                rp_okay <= rx_valid && (~{rx_crc16[0],rx_crc16[1],rx_crc16[2],rx_crc16[3],rx_crc16[4],rx_crc16[5],rx_crc16[6],rx_crc16[7],rx_crc16[8],rx_crc16[9],rx_crc16[10],rx_crc16[11],rx_crc16[12],rx_crc16[13],rx_crc16[14],rx_crc16[15]} == rx_shift[23:8]);
            default:               // special packet   //
                rp_okay <= 1'b0;
        endcase
    end

endmodule
