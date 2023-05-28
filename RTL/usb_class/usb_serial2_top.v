
//--------------------------------------------------------------------------------------------------------
// Module  : usb_serial2_top
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A USB Full Speed (12Mbps) device, act as a 2-channel USB CDC device (USB-Serial)
//--------------------------------------------------------------------------------------------------------

module usb_serial2_top #(
    parameter          DEBUG = "FALSE"  // whether to output USB debug info, "TRUE" or "FALSE"
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
    output wire [ 7:0] recv1_data,    // received data byte
    output wire        recv1_valid,   // when valid=1 pulses, a data byte is received on data
    // CDC send data (device-to-host)
    input  wire [ 7:0] send1_data,    // data byte to send
    input  wire        send1_valid,   // when device want to send a data byte, set valid=1. the data byte will be sent successfully when (valid=1 && ready=1).
    output wire        send1_ready,   // ready handshakes with valid. ready=1 indicates send-buffer is not full and will accept the byte on send_data. ready=0 indicates send-buffer is full and cannot accept a new byte. 
    // CDC receive data (host-to-device)
    output wire [ 7:0] recv2_data,    // received data byte
    output wire        recv2_valid,   // when valid=1 pulses, a data byte is received on data
    // CDC send data (device-to-host)
    input  wire [ 7:0] send2_data,    // data byte to send
    input  wire        send2_valid,   // when device want to send a data byte, set valid=1. the data byte will be sent successfully when (valid=1 && ready=1).
    output wire        send2_ready,   // ready handshakes with valid. ready=1 indicates send-buffer is not full and will accept the byte on send_data. ready=0 indicates send-buffer is full and cannot accept a new byte. 
    // debug output info, only for USB developers, can be ignored for normally use. Please set DEBUG="TRUE" to enable these signals
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    // 
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);


localparam   ASIZE = 10;     // send buffer size = 2^ASIZE


//-------------------------------------------------------------------------------------------------------------------------------------
// send-buffer (for device-to-host) for channel 1, size=1024B
//-------------------------------------------------------------------------------------------------------------------------------------

reg  [7:0] in1_data;
reg        in1_valid = 1'b0;
wire       in1_ready;

reg  [7:0] buff1 [(1<<ASIZE)-1 : 0];  // may automatically synthesize to BRAM
reg [ASIZE:0] wptr1, rptr1;

assign send1_ready = (wptr1 != {~rptr1[ASIZE], rptr1[ASIZE-1:0]});

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        wptr1 <= 0;
    end else begin
        if (send1_valid & send1_ready)
            wptr1 <= wptr1 + 1;
    end

always @ (posedge clk)
    if (send1_valid & send1_ready)
        buff1[wptr1[ASIZE-1:0]] <= send1_data;

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        in1_valid <= 1'b0;
        rptr1 <= 0;
    end else begin
        in1_valid <= (wptr1 != rptr1);
        if (in1_valid & in1_ready)
            rptr1 <= rptr1 + 1;
    end

always @ (posedge clk)
    in1_data <= buff1[rptr1[ASIZE-1:0]];




//-------------------------------------------------------------------------------------------------------------------------------------
// send-buffer (for device-to-host) for channel 2, size=1024B
//-------------------------------------------------------------------------------------------------------------------------------------

reg  [7:0] in2_data;
reg        in2_valid = 1'b0;
wire       in2_ready;

reg  [7:0] buff2 [(1<<ASIZE)-1 : 0];  // may automatically synthesize to BRAM
reg [ASIZE:0] wptr2, rptr2;

assign send2_ready = (wptr2 != {~rptr2[ASIZE], rptr2[ASIZE-1:0]});

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        wptr2 <= 0;
    end else begin
        if (send2_valid & send2_ready)
            wptr2 <= wptr2 + 1;
    end

always @ (posedge clk)
    if (send2_valid & send2_ready)
        buff2[wptr2[ASIZE-1:0]] <= send2_data;

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        in2_valid <= 1'b0;
        rptr2 <= 0;
    end else begin
        in2_valid <= (wptr2 != rptr2);
        if (in2_valid & in2_ready)
            rptr2 <= rptr2 + 1;
    end

always @ (posedge clk)
    in2_data <= buff2[rptr2[ASIZE-1:0]];




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( {  //  18 bytes available
        144'h12_01_10_01_EF_02_01_20_9A_FB_9A_FB_00_01_01_02_00_01
    } ),
    .DESCRIPTOR_STR1    ( {  //  64 bytes available
        352'h2C_03_67_00_69_00_74_00_68_00_75_00_62_00_2e_00_63_00_6f_00_6d_00_2f_00_57_00_61_00_6e_00_67_00_58_00_75_00_61_00_6e_00_39_00_35_00,                   // "github.com/WangXuan95"
        160'h0
    } ),
    .DESCRIPTOR_STR2    ( {  //  64 bytes available
        400'h32_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_53_00_65_00_72_00_69_00_61_00_6c_00_2d_00_32_00_63_00_68_00_61_00_6e_00_6e_00_65_00_6c_00, // "FPGA-USB-Serial-2channel"
        112'h0
    } ),
    .DESCRIPTOR_STR4    ( {  //  64 bytes available
        400'h32_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_53_00_65_00_72_00_69_00_61_00_6c_00_2d_00_63_00_68_00_61_00_6e_00_6e_00_65_00_6c_00_31_00, // "FPGA-USB-Serial-channel1"
        112'h0
    } ),
    .DESCRIPTOR_STR5    ( {  //  64 bytes available
        400'h32_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_53_00_65_00_72_00_69_00_61_00_6c_00_2d_00_63_00_68_00_61_00_6e_00_6e_00_65_00_6c_00_32_00, // "FPGA-USB-Serial-channel2"
        112'h0
    } ),
    .DESCRIPTOR_CONFIG  ( {  // 512 bytes available
        72'h09_02_79_00_04_01_00_80_64,        // configuration descriptor
        64'h08_0B_00_02_02_02_01_04,           // interface association descriptor, CDC interface collection
        72'h09_04_00_00_01_02_02_01_00,        // interface descriptor (communication control class)
        32'h04_24_02_0F,                       // functional descriptor (abstract control management)
        40'h05_24_06_00_01,                    // functional descriptor (union)
        56'h07_05_88_03_08_00_FF,              // endpoint descriptor (notify IN)
        72'h09_04_01_00_02_0A_00_00_00,        // interface descriptor (communication data class)
        56'h07_05_81_02_40_00_00,              // endpoint descriptor (data IN)
        56'h07_05_01_02_20_00_00,              // endpoint descriptor (data OUT)
        64'h08_0B_02_02_02_02_01_05,           // interface association descriptor, CDC interface collection
        72'h09_04_02_00_01_02_02_01_00,        // interface descriptor (communication control class)
        32'h04_24_02_0F,                       // functional descriptor (abstract control management)
        40'h05_24_06_02_03,                    // functional descriptor (union)                                // ***bug fixed at 20230527. The previous incorrect code was 40'h_05_24_06_02_01. The channel2 was not able to recognized by Linux
        56'h07_05_89_03_08_00_FF,              // endpoint descriptor (notify IN)
        72'h09_04_03_00_02_0A_00_00_00,        // interface descriptor (communication data class)
        56'h07_05_82_02_40_00_00,              // endpoint descriptor (data IN)
        56'h07_05_02_02_20_00_00,              // endpoint descriptor (data OUT)
        3128'h0
    } ),
    .EP81_MAXPKTSIZE    ( 10'h20           ),   // Here, I make the maximum packet length actually sent by the in endpoint (0x20) be less than the maximum packet length specified by the endpoint descriptor (0x40), not equal to it. Because the test shows that when the actual sent packet length = the maximum packet length specified by the descriptor, the host will not submit the received data to the software immediately (unknown reason).
    .EP82_MAXPKTSIZE    ( 10'h20           ),
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
    .ep81_data          ( in1_data         ),
    .ep81_valid         ( in1_valid        ),
    .ep81_ready         ( in1_ready        ),
    .ep82_data          ( in2_data         ),
    .ep82_valid         ( in2_valid        ),
    .ep82_ready         ( in2_ready        ),
    .ep83_data          ( 8'h0             ),
    .ep83_valid         ( 1'b0             ),
    .ep83_ready         (                  ),
    .ep84_data          ( 8'h0             ),
    .ep84_valid         ( 1'b0             ),
    .ep84_ready         (                  ),
    .ep01_data          ( recv1_data       ),
    .ep01_valid         ( recv1_valid      ),
    .ep02_data          ( recv2_data       ),
    .ep02_valid         ( recv2_valid      ),
    .ep03_data          (                  ),
    .ep03_valid         (                  ),
    .ep04_data          (                  ),
    .ep04_valid         (                  ),
    .debug_en           ( debug_en         ),
    .debug_data         ( debug_data       ),
    .debug_uart_tx      ( debug_uart_tx    )
);


endmodule
