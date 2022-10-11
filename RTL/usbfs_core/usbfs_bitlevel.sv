
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_bitlevel
// Type    : synthesizable, IP's sub module
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: USB Full Speed (12Mbps) device bit level transceiver, include:
//             SYNC detection, NRZI decode, bit de-stuff
//             send SYNC, TX bit stuff, NRZI encode
//             packet sending can only be active after packet receiving, so this module is only for device (rather than host and hub)
//--------------------------------------------------------------------------------------------------------

module usbfs_bitlevel (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB-unplug when reset)
    input  wire        clk,           // require 60MHz
    // USB phy interface
    output reg         usb_oe,        // tri-state direct control signal of USB-D+ and USB-D-,  1:device TX,  0:device RX
    output reg         usb_dp_tx,     // USB-D+ output
    output reg         usb_dn_tx,     // USB-D- output
    input  wire        usb_dp_rx,     // USB-D+ input
    input  wire        usb_dn_rx,     // USB-D- input
    // RX bit-level signals
    output reg         rx_sta,        // rx_sta=1 pulse indicates a RX packet start
    output reg         rx_ena,        // rx_ena=1 pulse indicates there is a RX bit on rx_bit
    output reg         rx_bit,        // valid when rx_ena=1
    output reg         rx_fin,        // rx_fin=1 pulse indicates the end of RX packet
    // TX bit-level signals
    input  wire        tx_sta,        // decide whether to send a TX packet after a RX packet, If a TX packet is decided to send, you must set tx_sta=1 when rx_fin=1, or after 1, 2, and 3 cycles after rx_fin=1.
    output reg         tx_req,        // when sending a TX packet, tx_req=1 indicates it's the time to push a bit to tx_bit
    input  wire        tx_bit,        // must be valid at the cycle after tx_req=1
    input  wire        tx_fin         // indicates whether to end the TX packet, must be set to 1 or 0 at the cycle after tx_req=1, set tx_fin=1 indicates you want to end the TX packet (rather than to send a bit on tx_bit)
);

localparam CNTJ_BEFORE_RX = 6'd17;
localparam CNTJ_BEFORE_TX = 6'd14;
localparam CNT_STUFF      = 6'd6;

initial {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b010;
initial {rx_sta, rx_ena, rx_bit, rx_fin, tx_req} = '0;


reg  [ 4:0] dpl = '0;
reg  [ 4:0] dnl = '0;

wire        dpv = &dpl[3:2] | &dpl[2:1] | dpl[3] & dpl[1];
wire        dnv = &dnl[3:2] | &dnl[2:1] | dnl[3] & dnl[1];
wire        njl = ~dpl[0] | dnl[0];

// use the bit border to detect whether our clock runs faster/slower than the host. For compensating. Ensure that we will not have alignment errors when receiving long packets
wire        det_fast = ( (dpl[4] != dpl[3]) && (dpl[3] == dpl[2]) && (dpl[2] == dpl[1]) && (dpl[1] == dpl[0]) ) ||    
                       (                       (dpl[3] != dpl[2]) && (dpl[2] == dpl[1]) && (dpl[1] == dpl[0]) ) ;
wire        det_slow = ( (dpl[4] == dpl[3]) && (dpl[3] == dpl[2]) && (dpl[2] == dpl[1]) && (dpl[1] != dpl[0]) ) ||
                       ( (dpl[4] == dpl[3]) && (dpl[3] == dpl[2]) && (dpl[2] != dpl[1])                       ) ;

// other simpler faster/slower detection, which also works. But I believe its effect is not as good as the complicated one.
//wire        det_fast = (dpl[3] != dpl[2]) && (dpl[2] == dpl[1]);
//wire        det_slow = (dpl[3] == dpl[2]) && (dpl[2] != dpl[1]);

reg         lastdp = 1'b0;
reg  [ 2:0] cnt_clk = 3'd4;    // down-counter, range: 4-0 (normally), 5-0 (fast compensate), 3-0 (slow compensate)
reg  [ 5:0] cnt_bit = '0;

wire        cnt_clk_eq2 = cnt_clk == 3'd2;
wire        cnt_clk_eq0 = cnt_clk == 3'd0;
wire [ 7:0] sync_byte = 8'b00101010;

enum logic [3:0] {JWAIT, IDLE, SYNC, DATA, DONE, TXWAIT, TXOE, TXSYNC, TXDATA, TXEOP1, TXEOP2, TXDONE} status = JWAIT;




// dp dn latch ---------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk)
    if(~rstn) begin
        dpl <= '0;
        dnl <= '0;
    end else begin
        dpl <= {dpl[3:0], usb_dp_rx};
        dnl <= {dnl[3:0], usb_dn_rx};
    end


// save last dpv (J) for NRZI decode -----------------------------------------------------------------------------------------------------------------
always @ (posedge clk)
    if(~rstn)
        lastdp <= '0;
    else
        if(cnt_clk_eq0) lastdp <= dpv;


// main FSM ------------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk)
    if(~rstn) begin
        {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b010;
        {rx_sta, rx_ena, rx_bit, rx_fin, tx_req} <= '0;
        cnt_clk <= 3'd4;
        cnt_bit <= '0;
        status <= JWAIT;
    end else begin
        {rx_sta, rx_ena, rx_bit, rx_fin, tx_req} <= '0;
        cnt_clk <= cnt_clk_eq0 ? 3'd4 : cnt_clk - 3'd1;
        case(status)
            JWAIT  :
                if(njl) begin
                    cnt_bit <= '0;
                end else if(cnt_bit < CNTJ_BEFORE_RX) begin
                    cnt_bit <= cnt_bit + 6'd1;
                end else begin
                    cnt_bit <= '0;
                    status <= IDLE;
                end
            IDLE   :
                if(njl) begin
                    cnt_clk <= 3'd3;
                    status <= SYNC;
                end
            SYNC   :
                if(cnt_clk_eq0) begin
                    if(dpv != sync_byte[cnt_bit] || dnv == sync_byte[cnt_bit]) begin
                        cnt_bit <= '0;
                        status <= JWAIT;
                    end else if(cnt_bit >= 6'd7) begin
                        cnt_bit <= 6'd1;
                        status <= DATA;
                        rx_sta <= 1'b1;
                    end else begin
                        cnt_bit <= cnt_bit + 6'd1;
                    end
                end
            DATA   :
                if(cnt_clk_eq0) begin
                    cnt_bit <= 6'd0;
                    if         ( dpv &  dnv) begin              // SE1 error
                        status <= JWAIT;
                    end else if(~dpv & ~dnv) begin              // SE0, maybe EOP
                        rx_fin <= 1'b1;
                        status <= DONE;
                    end else if(cnt_bit >= CNT_STUFF) begin     // the input bit is stuff bit
                        if (dpv == lastdp) status <= JWAIT;     //   stuff error
                    end else if(dpv == lastdp) begin            // 1
                        cnt_bit <= cnt_bit + 6'd1;
                        {rx_ena, rx_bit} <= 2'b11;
                    end else begin                              // 0
                        {rx_ena, rx_bit} <= 2'b10;
                    end
                    if(det_fast)                                // our clock runs too fast
                        cnt_clk <= 3'd5;                        //   fast compensate : let us slower
                    else if(det_slow)                           // our clock runs too slow
                        cnt_clk <= 3'd3;                        //   slow compensate : let us faster
                end
            DONE   :
                if(tx_sta)
                    status <= TXWAIT;
                else if(cnt_clk_eq0)
                    status <= JWAIT;
            TXWAIT :
                if(njl) begin
                    cnt_bit <= '0;
                end else if(cnt_bit < CNTJ_BEFORE_TX) begin
                    cnt_bit <= cnt_bit + 6'd1;
                end else begin
                    cnt_bit <= '0;
                    status <= TXOE;
                end
            TXOE   :
                if(cnt_clk_eq0) begin
                    {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b110;
                    status <= TXSYNC;
                end
            TXSYNC :
                if(cnt_clk_eq0) begin
                    {usb_oe, usb_dp_tx, usb_dn_tx} = {1'b1, sync_byte[cnt_bit], ~sync_byte[cnt_bit]};
                    if(cnt_bit >= 6'd7) begin
                        cnt_bit <= 6'd1;
                        status <= TXDATA;
                    end else begin
                        cnt_bit <= cnt_bit + 6'd1;
                    end
                end
            TXDATA :
                if(cnt_clk_eq2) begin
                    tx_req <= ~(cnt_bit >= CNT_STUFF);
                end else if(cnt_clk_eq0) begin
                    if(cnt_bit >= CNT_STUFF) begin
                        cnt_bit <= '0;
                        {usb_oe, usb_dp_tx, usb_dn_tx} = {1'b1, ~usb_dp_tx, usb_dp_tx};
                    end else if(tx_fin) begin
                        cnt_bit <= '0;
                        {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b100;
                        status <= TXEOP1;
                    end else if(~tx_bit) begin
                        cnt_bit <= '0;
                        {usb_oe, usb_dp_tx, usb_dn_tx} = {1'b1, ~usb_dp_tx, usb_dp_tx};
                    end else begin
                        cnt_bit <= cnt_bit + 6'd1;
                    end
                end
            TXEOP1:
                if(cnt_clk_eq0) begin
                    {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b100;
                    status <= TXEOP2;
                end
            TXEOP2:
                if(cnt_clk_eq0) begin
                    {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b110;
                    status <= TXDONE;
                end
            TXDONE:
                if(cnt_clk_eq0) begin
                    {usb_oe, usb_dp_tx, usb_dn_tx} = 3'b010;
                    cnt_bit <= 6'd5;
                    status <= JWAIT;
                end
            default:
                status <= JWAIT;
        endcase
    end

endmodule
