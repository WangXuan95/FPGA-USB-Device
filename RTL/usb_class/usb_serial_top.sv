
//--------------------------------------------------------------------------------------------------------
// Module  : usb_serial_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: A USB Full Speed (12Mbps) device, act as a USB CDC device (USB-Serial)
//--------------------------------------------------------------------------------------------------------

module usb_serial_top #(
    parameter          DEBUG = "FALSE"   // whether to output USB debug info, "TRUE" or "FALSE"
) (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset), normally set to 1
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // USB reset output
    output wire        usb_rstn,      // 1: connected , 0: disconnected (when USB cable unplug, or when system reset (rstn=0))
    // CDC receive data (host-to-device)
    output wire [ 7:0] recv_data,     // received data byte
    output wire        recv_valid,    // when recv_valid=1 pulses, a data byte is received on recv_data
    // CDC send data (device-to-host)
    input  wire [ 7:0] send_data,     // data byte to send
    input  wire        send_valid,    // when device want to send a data byte, set send_valid=1. the data byte will be sent successfully when (send_valid=1 && send_ready=1).
    output wire        send_ready,    // send_ready handshakes with send_valid. send_ready=1 indicates send-buffer is not full and will accept the byte on send_data. send_ready=0 indicates send-buffer is full and cannot accept a new byte. 
    // debug output info, only for USB developers, can be ignored for normally use
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    // 
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);


localparam   ASIZE = 10;     // send buffer size = 2^ASIZE


//-------------------------------------------------------------------------------------------------------------------------------------
// send-buffer (for device-to-host), size=1024B
//-------------------------------------------------------------------------------------------------------------------------------------

reg  [7:0] in_data;
reg        in_valid = '0;
wire       in_ready;

reg  [7:0] buff [1<<ASIZE];  // may automatically synthesize to BRAM
reg [ASIZE:0] wptr, rptr;
assign send_ready = wptr != {~rptr[ASIZE], rptr[ASIZE-1:0]};

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        wptr <= '0;
    end else begin
        if(send_valid & send_ready)
            wptr <= wptr + (1+ASIZE)'(1);
    end

always @ (posedge clk)
    if(send_valid & send_ready)
        buff[wptr[ASIZE-1:0]] <= send_data;

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        in_valid <= '0;
        rptr <= '0;
    end else begin
        in_valid <= wptr != rptr;
        if(in_valid & in_ready)
            rptr <= rptr + (1+ASIZE)'(1);
    end

always @ (posedge clk)
    in_data <= buff[rptr[ASIZE-1:0]];




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( '{  //  18 bytes available
        'h12, 'h01, 'h10, 'h01, 'h02, 'h00, 'h00, 'h20, 'h9A, 'hFB, 'h9A, 'hFB, 'h00, 'h01, 'h01, 'h02, 'h00, 'h01
    } ),
    .DESCRIPTOR_STR1    ( '{  //  64 bytes available
        'h2C, 'h03, "g" , 'h00, "i" , 'h00, "t" , 'h00, "h" , 'h00, "u" , 'h00, "b" , 'h00, "." , 'h00, "c" , 'h00, "o" , 'h00, "m" , 'h00, "/" , 'h00, "W" , 'h00, "a" , 'h00, "n" , 'h00, "g" , 'h00, "X" , 'h00, "u" , 'h00, "a" , 'h00, "n" , 'h00, "9" , 'h00, "5" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_STR2    ( '{  //  64 bytes available
        'h20, 'h03, "F" , 'h00, "P" , 'h00, "G" , 'h00, "A" , 'h00, "-" , 'h00, "U" , 'h00, "S" , 'h00, "B" , 'h00, "-" , 'h00, "S" , 'h00, "e" , 'h00, "r" , 'h00, "i" , 'h00, "a" , 'h00, "l" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_CONFIG  ( '{  // 512 bytes available
        'h09, 'h02, 'h39, 'h00, 'h02, 'h01, 'h00, 'h80, 'h64,    // configuration descriptor
        'h09, 'h04, 'h00, 'h00, 'h01, 'h02, 'h02, 'h01, 'h00,    // interface descriptor (communication control class)
        'h04, 'h24, 'h02, 'h00,                                  // functional descriptor (abstract control management)
        'h05, 'h24, 'h06, 'h00, 'h01,                            // functional descriptor (union)
        'h07, 'h05, 'h88, 'h03, 'h08, 'h00, 'hFF,                // endpoint descriptor (notify IN)
        'h09, 'h04, 'h01, 'h00, 'h02, 'h0A, 'h00, 'h00, 'h00,    // interface descriptor (communication data class)
        'h07, 'h05, 'h81, 'h02, 'h40, 'h00, 'h00,                // endpoint descriptor (data IN)
        'h07, 'h05, 'h01, 'h02, 'h20, 'h00, 'h00,                // endpoint descriptor (data OUT)
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .EP81_MAXPKTSIZE    ( 10'h20           ),   // Here, I make the maximum packet length actually sent by the in endpoint (0x20) be less than the maximum packet length specified by the endpoint descriptor (0x40), not equal to it. Because the test shows that when the actual sent packet length = the maximum packet length specified by the descriptor, the host will not submit the received data to the software immediately (unknown reason).
    .DEBUG              ( DEBUG            )
) usbfs_core_i (
    .rstn               ( rstn             ),
    .clk                ( clk              ),
    .usb_dp_pull        ( usb_dp_pull      ),
    .usb_dp             ( usb_dp           ),
    .usb_dn             ( usb_dn           ),
    .usb_rstn           ( usb_rstn         ),
    .sot                (                  ),
    .sof                (                  ),
    .ep00_setup_cmd     (                  ),
    .ep00_resp_idx      (                  ),
    .ep00_resp          ( 8'h0             ),
    .ep81_data          ( in_data          ),
    .ep81_valid         ( in_valid         ),
    .ep81_ready         ( in_ready         ),
    .ep82_data          ( 8'h0             ),
    .ep82_valid         ( 1'b0             ),
    .ep82_ready         (                  ),
    .ep83_data          ( 8'h0             ),
    .ep83_valid         ( 1'b0             ),
    .ep83_ready         (                  ),
    .ep84_data          ( 8'h0             ),
    .ep84_valid         ( 1'b0             ),
    .ep84_ready         (                  ),
    .ep01_data          ( recv_data        ),
    .ep01_valid         ( recv_valid       ),
    .ep02_data          (                  ),
    .ep02_valid         (                  ),
    .ep03_data          (                  ),
    .ep03_valid         (                  ),
    .ep04_data          (                  ),
    .ep04_valid         (                  ),
    .debug_en           ( debug_en         ),
    .debug_data         ( debug_data       ),
    .debug_uart_tx      ( debug_uart_tx    )
);


endmodule
