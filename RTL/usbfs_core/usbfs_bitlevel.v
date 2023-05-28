
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_bitlevel
// Type    : synthesizable, IP's sub module
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: USB Full Speed (12Mbps) device bit level transceiver, include:
//             S_SYNC detection, NRZI decode, bit de-stuff
//             send S_SYNC, TX bit stuff, NRZI encode
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



localparam [5:0] CNTJ_BEFORE_RX = 6'd17;
localparam [5:0] CNTJ_BEFORE_TX = 6'd14;
localparam [5:0] CNT_STUFF      = 6'd6;


initial usb_oe    = 1'b0;
initial usb_dp_tx = 1'b1;
initial usb_dn_tx = 1'b0;
initial rx_sta    = 1'b0;
initial rx_ena    = 1'b0;
initial rx_bit    = 1'b0;
initial rx_fin    = 1'b0;
initial tx_req    = 1'b0;


reg  [ 4:0] dpl = 5'h0;
reg  [ 4:0] dnl = 5'h0;

wire        dpv = &dpl[3:2] | &dpl[2:1] | dpl[3] & dpl[1];
wire        dnv = &dnl[3:2] | &dnl[2:1] | dnl[3] & dnl[1];
wire        njl = ~dpl[0] | dnl[0];

// use the bit border to detect whether our clock runs faster/slower than the host. For compensating. Ensure that we will not have alignment errors when receiving long packets
wire        det_fast = ( (dpl[4] != dpl[3]) && (dpl[3] == dpl[2]) && (dpl[2] == dpl[1]) && (dpl[1] == dpl[0]) ) ||    
                       (                       (dpl[3] != dpl[2]) && (dpl[2] == dpl[1]) && (dpl[1] == dpl[0]) ) ;
wire        det_slow = ( (dpl[4] == dpl[3]) && (dpl[3] == dpl[2]) && (dpl[2] == dpl[1]) && (dpl[1] != dpl[0]) ) ||
                       ( (dpl[4] == dpl[3]) && (dpl[3] == dpl[2]) && (dpl[2] != dpl[1])                       ) ;

// anothor simpler faster/slower detection, which also works. But I believe it is not as good as the complicated one.
//wire        det_fast = (dpl[3] != dpl[2]) && (dpl[2] == dpl[1]);
//wire        det_slow = (dpl[3] == dpl[2]) && (dpl[2] != dpl[1]);

reg         lastdp  = 1'b0;
reg  [ 2:0] cnt_clk = 3'd4;    // down-counter, range: 4-0 (normally), 5-0 (fast compensate), 3-0 (slow compensate)
reg  [ 5:0] cnt_bit = 6'd0;

wire        cnt_clk_eq2 = (cnt_clk == 3'd2);
wire        cnt_clk_eq0 = (cnt_clk == 3'd0);

localparam [7:0] SYNC_PATTERN = 8'b00101010;


// FSM states ---------------------------------------------------------------------------------------------------------------------------------------
localparam [3:0] S_JWAIT   = 4'd0 ,
                 S_IDLE    = 4'd1 ,
                 S_SYNC    = 4'd2 ,
                 S_DATA    = 4'd3 ,
                 S_DONE    = 4'd4 ,
                 S_TXWAIT  = 4'd5 ,
                 S_TXOE    = 4'd6 ,
                 S_TXSYNC  = 4'd7 ,
                 S_TXDATA  = 4'd8 ,
                 S_TXEOP1  = 4'd9 ,
                 S_TXEOP2  = 4'd10,
                 S_TXDONE  = 4'd11;

reg  [ 3:0] state = S_JWAIT;



// dp dn latch ---------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        dpl <= 5'h0;
        dnl <= 5'h0;
    end else begin
        dpl <= {dpl[3:0], usb_dp_rx};
        dnl <= {dnl[3:0], usb_dn_rx};
    end


// save last dpv (J) for NRZI decode -----------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        lastdp <= 1'b0;
    end else begin
        if (cnt_clk_eq0)
            lastdp <= dpv;
    end


// main FSM ------------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        usb_oe    <= 1'b0;
        usb_dp_tx <= 1'b1;
        usb_dn_tx <= 1'b0;
        rx_sta    <= 1'b0;
        rx_ena    <= 1'b0;
        rx_bit    <= 1'b0;
        rx_fin    <= 1'b0;
        tx_req    <= 1'b0;
        cnt_clk   <= 3'd4;
        cnt_bit   <= 6'd0;
        state     <= S_JWAIT;
    end else begin
        rx_sta    <= 1'b0;
        rx_ena    <= 1'b0;
        rx_bit    <= 1'b0;
        rx_fin    <= 1'b0;
        tx_req    <= 1'b0;
        cnt_clk   <= cnt_clk_eq0 ? 3'd4 : cnt_clk - 3'd1;
        
        case(state)
            S_JWAIT  :
                if (njl) begin
                    cnt_bit <= 6'd0;
                end else if (cnt_bit < CNTJ_BEFORE_RX) begin
                    cnt_bit <= cnt_bit + 6'd1;
                end else begin
                    cnt_bit <= 6'd0;
                    state <= S_IDLE;
                end
            
            S_IDLE   :
                if (njl) begin
                    cnt_clk <= 3'd3;
                    state <= S_SYNC;
                end
            
            S_SYNC   :
                if (cnt_clk_eq0) begin
                    if (dpv != SYNC_PATTERN[cnt_bit] || dnv == SYNC_PATTERN[cnt_bit]) begin
                        cnt_bit <= 6'd0;
                        state <= S_JWAIT;
                    end else if (cnt_bit >= 6'd7) begin
                        cnt_bit <= 6'd1;
                        state <= S_DATA;
                        rx_sta <= 1'b1;
                    end else begin
                        cnt_bit <= cnt_bit + 6'd1;
                    end
                end
            
            S_DATA   :
                if (cnt_clk_eq0) begin
                    cnt_bit <= 6'd0;
                    if         ( dpv &  dnv) begin              // SE1 error
                        state <= S_JWAIT;
                    end else if (~dpv & ~dnv) begin             // SE0, maybe EOP
                        rx_fin <= 1'b1;
                        state <= S_DONE;
                    end else if (cnt_bit >= CNT_STUFF) begin    // the input bit is stuff bit
                        if (dpv == lastdp) state <= S_JWAIT;    //   stuff error
                    end else if (dpv == lastdp) begin           // 1
                        cnt_bit <= cnt_bit + 6'd1;
                        rx_ena <= 1'b1;
                        rx_bit <= 1'b1;
                    end else begin                              // 0
                        rx_ena <= 1'b1;
                        rx_bit <= 1'b0;
                    end
                    if (det_fast)                               // our clock runs too fast
                        cnt_clk <= 3'd5;                        //   fast compensate : let us slower
                    else if (det_slow)                          // our clock runs too slow
                        cnt_clk <= 3'd3;                        //   slow compensate : let us faster
                end
            
            S_DONE   :
                if (tx_sta)
                    state <= S_TXWAIT;
                else if (cnt_clk_eq0)
                    state <= S_JWAIT;
            
            S_TXWAIT :
                if (njl) begin
                    cnt_bit <= 6'd0;
                end else if (cnt_bit < CNTJ_BEFORE_TX) begin
                    cnt_bit <= cnt_bit + 6'd1;
                end else begin
                    cnt_bit <= 6'd0;
                    state <= S_TXOE;
                end
            
            S_TXOE   :
                if (cnt_clk_eq0) begin
                    usb_oe    <= 1'b1;
                    usb_dp_tx <= 1'b1;
                    usb_dn_tx <= 1'b0;
                    state <= S_TXSYNC;
                end
            
            S_TXSYNC :
                if (cnt_clk_eq0) begin
                    usb_oe    <= 1'b1;
                    usb_dp_tx <=  SYNC_PATTERN[cnt_bit];
                    usb_dn_tx <= ~SYNC_PATTERN[cnt_bit];
                    if (cnt_bit >= 6'd7) begin
                        cnt_bit <= 6'd1;
                        state <= S_TXDATA;
                    end else begin
                        cnt_bit <= cnt_bit + 6'd1;
                    end
                end
            
            S_TXDATA :
                if (cnt_clk_eq2) begin
                    tx_req <= ~(cnt_bit >= CNT_STUFF);
                end else if (cnt_clk_eq0) begin
                    if (cnt_bit >= CNT_STUFF) begin
                        cnt_bit <= 6'd0;
                        usb_oe    <= 1'b1;
                        usb_dp_tx <= ~usb_dp_tx;
                        usb_dn_tx <=  usb_dp_tx;
                    end else if (tx_fin) begin
                        cnt_bit <= 6'd0;
                        usb_oe    <= 1'b1;
                        usb_dp_tx <= 1'b0;
                        usb_dn_tx <= 1'b0;
                        state <= S_TXEOP1;
                    end else if (~tx_bit) begin
                        cnt_bit <= 6'd0;
                        usb_oe    <= 1'b1;
                        usb_dp_tx <= ~usb_dp_tx;
                        usb_dn_tx <=  usb_dp_tx;
                    end else begin
                        cnt_bit <= cnt_bit + 6'd1;
                    end
                end
            
            S_TXEOP1 :
                if (cnt_clk_eq0) begin
                    usb_oe    <= 1'b1;
                    usb_dp_tx <= 1'b0;
                    usb_dn_tx <= 1'b0;
                    state <= S_TXEOP2;
                end
            
            S_TXEOP2 :
                if (cnt_clk_eq0) begin
                    usb_oe    <= 1'b1;
                    usb_dp_tx <= 1'b1;
                    usb_dn_tx <= 1'b0;
                    state <= S_TXDONE;
                end
            
            default :  // S_TXDONE :
                if (cnt_clk_eq0) begin
                    usb_oe    <= 1'b0;
                    usb_dp_tx <= 1'b1;
                    usb_dn_tx <= 1'b0;
                    cnt_bit <= 6'd5;
                    state <= S_JWAIT;
                end
        endcase
    end

endmodule
