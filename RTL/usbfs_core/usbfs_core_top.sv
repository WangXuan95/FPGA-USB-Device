
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_core_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: A USB Full Speed (12Mbps) device controller
//--------------------------------------------------------------------------------------------------------

module usbfs_core_top #(
    parameter [9:0] ENDP_00_MAXPKTSIZE = 10'd32,
    parameter [9:0] ENDP_81_MAXPKTSIZE = 10'd32
) (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset)
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // USB reset output
    output reg         usb_rstn,
    // descriptor ROM read interface, connect to a descriptor ROM
    output wire [ 9:0] desc_addr,     // give out a descriptor ROM address
    input  wire [ 7:0] desc_data,     // descriptor ROM
    // endpoint 0x01 data output (host-to-device)
    output wire [ 7:0] out_data,      // OUT data byte
    output wire        out_valid,     // when out_valid=1 pulses, a data byte is received on out_data
    // endpoint 0x81 data input (device-to-host)
    input  wire [ 7:0] in_data,       // IN data byte
    input  wire        in_valid,      // when device want to send a data byte, assert in_valid=1. the data byte will be sent successfully when in_valid=1 & in_ready=1.
    output wire        in_ready       // in_ready handshakes with in_valid. in_ready=1 indicates the data byte can be accept.
);

initial {usb_dp_pull, usb_rstn} <= '0;

//-------------------------------------------------------------------------------------------------------------------------------------
// USB driving signals
//-------------------------------------------------------------------------------------------------------------------------------------
wire        usb_oe;
wire        usb_dp_tx;
wire        usb_dn_tx;

//-------------------------------------------------------------------------------------------------------------------------------------
// USB bit-level RX signals
//-------------------------------------------------------------------------------------------------------------------------------------
wire        rx_sta;
wire        rx_ena;
wire        rx_bit;
wire        rx_fin;

//-------------------------------------------------------------------------------------------------------------------------------------
// USB bit-level TX signals
//-------------------------------------------------------------------------------------------------------------------------------------
wire        tx_sta;
wire        tx_req;
wire        tx_bit;
wire        tx_fin;

//-------------------------------------------------------------------------------------------------------------------------------------
// USB packet-level RX signals
//-------------------------------------------------------------------------------------------------------------------------------------
wire [ 3:0] rp_pid;
wire [10:0] rp_addr;
wire        rp_byte_en;
wire [ 7:0] rp_byte;
wire        rp_fin;
wire        rp_okay;

//-------------------------------------------------------------------------------------------------------------------------------------
// USB packet-level TX signals
//-------------------------------------------------------------------------------------------------------------------------------------
wire        tp_sta;
wire [ 3:0] tp_pid;
wire        tp_byte_req;
wire [ 7:0] tp_byte;
wire        tp_fin_n;


//-------------------------------------------------------------------------------------------------------------------------------------
// USB reset control (device reset when rstn=0 and maintain for 1000ms, host reset when dp=dn=0 for 5us)
//-------------------------------------------------------------------------------------------------------------------------------------
localparam RESET_CYCLES = 60000000;  // 1000ms
reg  [31:0] usb_rstn_cnt = 0;
always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        usb_dp_pull <= 1'b0;
        usb_rstn <= 1'b0;
        usb_rstn_cnt <= 0;
    end else begin
        if(usb_rstn_cnt < RESET_CYCLES) begin
            usb_dp_pull <= 1'b0;
            usb_rstn <= 1'b0;
            usb_rstn_cnt <= usb_rstn_cnt + 1;
        end else if(usb_dp != usb_dn) begin
            usb_dp_pull <= 1'b1;
            usb_rstn <= 1'b1;
            usb_rstn_cnt <= RESET_CYCLES + 300;
        end else if(usb_rstn_cnt > RESET_CYCLES) begin
            usb_dp_pull <= 1'b1;
            usb_rstn <= 1'b1;
            usb_rstn_cnt <= usb_rstn_cnt - 1;
        end else begin
            usb_dp_pull <= 1'b1;
            usb_rstn <= 1'b0;
        end
    end


//-------------------------------------------------------------------------------------------------------------------------------------
// USB D+ and D- driver
//-------------------------------------------------------------------------------------------------------------------------------------
assign usb_dp = usb_oe ? usb_dp_tx : 1'bz;
assign usb_dn = usb_oe ? usb_dn_tx : 1'bz;


//-------------------------------------------------------------------------------------------------------------------------------------
// USB bit-level to driver
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_bitlevel usbfs_bitlevel_i (
    .rstn            ( usb_rstn         ),
    .clk             ( clk              ),
    .usb_oe          ( usb_oe           ),
    .usb_dp_tx       ( usb_dp_tx        ),
    .usb_dn_tx       ( usb_dn_tx        ),
    .usb_dp_rx       ( usb_dp           ),
    .usb_dn_rx       ( usb_dn           ),
    .rx_sta          ( rx_sta           ),
    .rx_ena          ( rx_ena           ),
    .rx_bit          ( rx_bit           ),
    .rx_fin          ( rx_fin           ),
    .tx_sta          ( tx_sta           ),
    .tx_req          ( tx_req           ),
    .tx_bit          ( tx_bit           ),
    .tx_fin          ( tx_fin           )
);


//-------------------------------------------------------------------------------------------------------------------------------------
// USB packet-level RX to bit-level RX
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_packet_rx usbfs_packet_rx_i (
    .rstn            ( usb_rstn         ),
    .clk             ( clk              ),
    .rx_sta          ( rx_sta           ),
    .rx_ena          ( rx_ena           ),
    .rx_bit          ( rx_bit           ),
    .rx_fin          ( rx_fin           ),
    .rp_pid          ( rp_pid           ),
    .rp_addr         ( rp_addr          ),
    .rp_byte_en      ( rp_byte_en       ),
    .rp_byte         ( rp_byte          ),
    .rp_fin          ( rp_fin           ),
    .rp_okay         ( rp_okay          )
);


//-------------------------------------------------------------------------------------------------------------------------------------
// USB packet-level TX to bit-level TX
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_packet_tx usbfs_packet_tx_i (
    .rstn            ( usb_rstn         ),
    .clk             ( clk              ),
    .tp_sta          ( tp_sta           ),
    .tp_pid          ( tp_pid           ),
    .tp_byte_req     ( tp_byte_req      ),
    .tp_byte         ( tp_byte          ),
    .tp_fin_n        ( tp_fin_n         ),
    .tx_sta          ( tx_sta           ),
    .tx_req          ( tx_req           ),
    .tx_bit          ( tx_bit           ),
    .tx_fin          ( tx_fin           )
);


//-------------------------------------------------------------------------------------------------------------------------------------
// USB transaction-level
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_transaction #(
    .ENDP_00_MAXPKTSIZE ( ENDP_00_MAXPKTSIZE ),
    .ENDP_81_MAXPKTSIZE ( ENDP_81_MAXPKTSIZE )
) usbfs_transaction_i (
    .rstn            ( usb_rstn         ),
    .clk             ( clk              ),
    .rp_pid          ( rp_pid           ),
    .rp_addr         ( rp_addr          ),
    .rp_byte_en      ( rp_byte_en       ),
    .rp_byte         ( rp_byte          ),
    .rp_fin          ( rp_fin           ),
    .rp_okay         ( rp_okay          ),
    .tp_sta          ( tp_sta           ),
    .tp_pid          ( tp_pid           ),
    .tp_byte_req     ( tp_byte_req      ),
    .tp_byte         ( tp_byte          ),
    .tp_fin_n        ( tp_fin_n         ),
    .desc_addr       ( desc_addr        ),
    .desc_data       ( desc_data        ),
    .out_data        ( out_data         ),
    .out_valid       ( out_valid        ),
    .in_data         ( in_data          ),
    .in_valid        ( in_valid         ),
    .in_ready        ( in_ready         )
);

endmodule
