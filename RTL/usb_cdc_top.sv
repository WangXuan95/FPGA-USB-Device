`timescale 1ns/1ns

module usb_cdc_top (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset)
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // CDC receive data (host-to-device)
    output wire [ 7:0] recv_data,     // received data byte
    output wire        recv_valid,    // when recv_valid=1 pulses, a data byte is received on recv_data
    // CDC send data (device-to-host)
    input  wire [ 7:0] send_data,     // data byte to send
    input  wire        send_valid,    // when device want to send a data byte, assert send_valid=1. the data byte will be sent successfully when (send_valid=1 && send_ready=1).
    output wire        send_ready     // send_ready handshakes with send_valid. send_ready=1 indicates send-buffer is not full and will accept the byte on send_data. send_ready=0 indicates send-buffer is full and cannot accept a new byte. 
);

//-------------------------------------------------------------------------------------------------------------------------------------
// descriptor ROM and ROM-read logic
//-------------------------------------------------------------------------------------------------------------------------------------
wire [7:0] descriptor_rom [1024] = '{
    // device descriptor                                                        offset=0x000(should fixed)  available-space=0x020
    8'h12, 8'h01, 8'h10, 8'h01, 8'h02, 8'h00, 8'h00, 8'h20, 8'h9a, 8'hfb, 8'h9a, 8'hfb, 8'h31, 8'h00, 8'h01, 8'h02, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 0 (supported languages)                                offset=0x020(should fixed)  available-space=0x020
    8'h04, 8'h03, 8'h09, 8'h04, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 1 (manufacturer, if any)                               offset=0x040(should fixed)  available-space=0x040
    8'h2C, 8'h03, "g"  , 8'h00, "i"  , 8'h00, "t"  , 8'h00, "h"  , 8'h00, "u"  , 8'h00, "b"  , 8'h00, "."  , 8'h00, "c"  , 8'h00, "o"  , 8'h00, "m"  , 8'h00, "/"  , 8'h00, "W"  , 8'h00, "a"  , 8'h00, "n"  , 8'h00, "g"  , 8'h00, "X"  , 8'h00, "u"  , 8'h00, "a"  , 8'h00, "n"  , 8'h00, "9"  , 8'h00, "5"  , 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 2 (product, if any)                                    offset=0x080(should fixed)  available-space=0x040
    8'h1A, 8'h03, "F"  , 8'h00, "P"  , 8'h00, "G"  , 8'h00, "A"  , 8'h00, " "  , 8'h00, "U"  , 8'h00, "S"  , 8'h00, "B"  , 8'h00, "-"  , 8'h00, "C"  , 8'h00, "D"  , 8'h00, "C"  , 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 3 (serial-number, if any)                              offset=0x0C0(should fixed)  available-space=0x040
    8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // configuration descriptor set                                             offset=0x100(should fixed)  available-space=0x200
    8'h09, 8'h02, 8'h43, 8'h00, 8'h02, 8'h01, 8'h00, 8'hC0, 8'h64,                  // configuration descriptor
    8'h09, 8'h04, 8'h00, 8'h00, 8'h01, 8'h02, 8'h02, 8'h01, 8'h00,                  // interface descriptor (communication control class)
    8'h05, 8'h24, 8'h00, 8'h10, 8'h01,                                              // functional descriptor (header)
    8'h04, 8'h24, 8'h02, 8'h00,                                                     // functional descriptor (abstract control management)
    8'h05, 8'h24, 8'h06, 8'h00, 8'h01,                                              // functional descriptor (union)
    8'h05, 8'h24, 8'h01, 8'h00, 8'h01,                                              // functional descriptor (call management)
    8'h07, 8'h05, 8'h82, 8'h03, 8'h08, 8'h00, 8'hFF,                                // endpoint descriptor (notify IN)
    8'h09, 8'h04, 8'h01, 8'h00, 8'h02, 8'h0A, 8'h00, 8'h00, 8'h00,                  // interface descriptor (communication data class)
    8'h07, 8'h05, 8'h81, 8'h02, 8'h20, 8'h00, 8'h00,                                // endpoint descriptor (data IN)
    8'h07, 8'h05, 8'h01, 8'h02, 8'h20, 8'h00, 8'h00,                                // endpoint descriptor (data OUT)
    8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,

    // HID descriptor (if any)                                                 offset=0x300(should fixed)  available-space=0x100
    8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00
};
wire [ 9:0] desc_addr;
reg  [ 7:0] desc_data = '0;
always @ (posedge clk) desc_data <= descriptor_rom[desc_addr];


//-------------------------------------------------------------------------------------------------------------------------------------
// send-buffer (for device-to-host), size=1024B
//-------------------------------------------------------------------------------------------------------------------------------------
wire        usb_rstn;
wire [ 7:0] in_data;
wire        in_valid;
wire        in_ready;
fifo in_data_buffer (
    .rstn            ( usb_rstn         ),
    .clk             ( clk              ),
    .itvalid         ( send_valid       ),
    .itready         ( send_ready       ),
    .itdata          ( send_data        ),
    .otvalid         ( in_valid         ),
    .otready         ( in_ready         ),
    .otdata          ( in_data          )
);


//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .ENDP_81_MAXPKTSIZE ( 10'd32        )
) usbfs_core_i (
    .rstn            ( rstn             ),
    .clk             ( clk              ),
    .usb_dp_pull     ( usb_dp_pull      ),
    .usb_dp          ( usb_dp           ),
    .usb_dn          ( usb_dn           ),
    .usb_rstn        ( usb_rstn         ),
    .desc_addr       ( desc_addr        ),
    .desc_data       ( desc_data        ),
    .out_data        ( recv_data        ),
    .out_valid       ( recv_valid       ),
    .in_data         ( in_data          ),
    .in_valid        ( in_valid         ),
    .in_ready        ( in_ready         )
);

endmodule












//-------------------------------------------------------------------------------------------------------------------------------------
// a generic sync fifo
//-------------------------------------------------------------------------------------------------------------------------------------
module fifo #(
    parameter   DSIZE = 8,
    parameter   ASIZE = 10
)(
    input  wire             rstn,
    input  wire             clk,
    input  wire             itvalid,
    output wire             itready,
    input  wire [DSIZE-1:0] itdata,
    output reg              otvalid,
    input  wire             otready,
    output wire [DSIZE-1:0] otdata
);

reg  [DSIZE-1:0] buffer [1<<ASIZE];  // may automatically synthesize to BRAM

logic [ASIZE:0] wptr, rptr;

wire full  = wptr == {~rptr[ASIZE], rptr[ASIZE-1:0]};
wire empty = wptr == rptr;

assign itready = rstn & ~full;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        wptr <= '0;
    end else begin
        if(itvalid & ~full)
            wptr <= wptr + (1+ASIZE)'(1);
    end

always @ (posedge clk)
    if(itvalid & ~full)
        buffer[wptr[ASIZE-1:0]] <= itdata;

wire            rdready = ~otvalid | otready;
reg             rdack;
reg [DSIZE-1:0] rddata;
reg [DSIZE-1:0] keepdata;
assign otdata = rdack ? rddata : keepdata;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        otvalid <= 1'b0;
        rdack <= 1'b0;
        rptr <= '0;
        keepdata <= '0;
    end else begin
        otvalid <= ~empty | ~rdready;
        rdack <= ~empty & rdready;
        if(~empty & rdready)
            rptr <= rptr + (1+ASIZE)'(1);
        if(rdack)
            keepdata <= rddata;
    end

always @ (posedge clk)
    rddata <= buffer[rptr[ASIZE-1:0]];

endmodule
