
//--------------------------------------------------------------------------------------------------------
// Module  : usb_camera_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: A USB Full Speed (12Mbps) device, act as a USB UVC camera
//
// paramter FRAME_TYPE and be "MONO" or "YUY2 :
//
//     "MONO"  : monochrome (gray-scale) video-frame, each pixel consists of 1 byte.
//               For example, for a 4x3 image, this module will fetch 12 bytes in the order of:
//                  Y00  Y01  Y02  Y03  Y10  Y11  Y12  Y13  Y20  Y21  Y22  Y23
//               Where Y00 is the pixel of row 0 column 0, Y01 is the pixel of row 0 column 1 ...
//
//     "YUY2"  : Colored video-frame, also known as YUYV.
//               Each pixel has its own luminance (Y) byte,
//               while every two adjacent pixels share a chroma-blue (U) byte and a chroma-red (V) byte.
//               For example, for a 4x2 image, this module will fetch 16 bytes in the order of:
//                  Y00  U00  Y01  V00  Y02  U02  Y03  V02  Y10  U10  Y11  V10  Y12  U12  Y13  V12
//               Where, (Y00, U00, V00) is the pixel of row 0 column 0,
//                      (Y01, U00, V00) is the pixel of row 0 column 1,
//                      (Y02, U02, V02) is the pixel of row 0 column 2,
//                      (Y03, U02, V02) is the pixel of row 0 column 3.
//--------------------------------------------------------------------------------------------------------

module usb_camera_top #(
    parameter        FRAME_TYPE = "YUY2",    // "MONO" or "YUY2"
    parameter [13:0] FRAME_W    = 14'd320,   // video-frame width  in pixels, must be a even number
    parameter [13:0] FRAME_H    = 14'd240,   // video-frame height in pixels, must be a even number
    parameter        DEBUG      = "FALSE"    // whether to output USB debug info, "TRUE" or "FALSE"
) (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset), normally set to 1
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // USB reset output
    output wire        usb_rstn,      // 1: connected , 0: disconnected (when USB cable unplug, or when system reset (rstn=0))
    // video frame fetch interface    //   start-of-frame |  frame data transmitting   | end-of-frame
    output reg         vf_sof,        // 0000000001000000000000000000000000000000000000000000000000000000    // vf_sof=1 indicate a start of video-frame
    output reg         vf_req,        // 0000000000000000010001000100010001000100010001000000000000000000    // when vf_req=1, a byte of pixel data on vf_byte need to be valid
    input  wire [ 7:0] vf_byte,       //                  D   D   D   D   D   D   D   D                      // a byte of pixel data
    // debug output info, only for USB developers, can be ignored for normally use
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    // 
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);


localparam [15:0] wWidth              = {2'h0, FRAME_W[13:1], 1'h0};                                                                    // video-frame width in pixels
localparam [15:0] wHeight             = {2'h0, FRAME_H[13:1], 1'h0};                                                                    // video-frame height in pixels
localparam [31:0] FramePixelCount     = (32)'(wHeight) * (32)'(wWidth);
localparam [31:0] dwMaxVideoFrameSize = FramePixelCount * 2;                                                                            // 2 bytes for each pixel
localparam [ 9:0] PacketSize          = 10'd802;                                                                                        // USB-packet = 2 byte header + PayloadSize bytes of pixel datas
localparam [31:0] PayloadSize         = (32)'(PacketSize) - 2;                                                                          // each USB-packet contains PayloadSize bytes (exclude the header)
localparam [31:0] FramePacketCount    = (dwMaxVideoFrameSize + PayloadSize - 1)  / PayloadSize;                                         // USB-packet count of one video-frame
localparam [31:0] LastPayloadSize     = (dwMaxVideoFrameSize % PayloadSize == 0) ? PayloadSize : (dwMaxVideoFrameSize % PayloadSize);   // size of the last USB-packet of one video-frame (exclude the header)
localparam [31:0] LastPacketSize      = LastPayloadSize + 2;                                                                            // size of the last USB-packet of one video-frame (include the header)
localparam [31:0] FrameInterval_ms    = FramePacketCount;                                                                               // video-frame interval (unit: 1ms), Note that USB send 1 USB-packet in each USB-frame (1ms), thus FrameInterval_ms = FramePacketCount
localparam [31:0] dwFrameInterval     = FrameInterval_ms * 10000;                                                                       // video-frame interval (unit: 100ns)




//-------------------------------------------------------------------------------------------------------------------------------------
// USB-packet generation for video transmitting
//-------------------------------------------------------------------------------------------------------------------------------------

initial {vf_sof, vf_req} = '0;

wire        sof;                                                  // this is a start of USB-frame, not video-frame

wire        in_ready;
reg         in_valid = '0;
reg  [ 7:0] in_data  = '0;

reg         is_y  = '0;
reg  [31:0] bcnt  = 0;                                            // byte count in one USB-packet (include packet header bytes)
reg  [31:0] pcnt  = 0;                                            // USB-packet count in one video-frame
wire        plast = (pcnt + 1 >= FramePacketCount);               // whether it is the last USB-packet of a video-frame
wire [31:0] psize = plast ? LastPacketSize : (32)'(PacketSize);   // size of the current USB-packet to send
reg         fid   = '0;                                           // toggle when each video-frame transmit done

always @ (posedge clk)
    if     ( bcnt == 0 )
        in_data <= 8'h02;                                         // HLE (header length) = 2
    else if( bcnt == 1 )
        in_data <= {6'b100000, plast, fid};                       // BFH[0]
    else if( FRAME_TYPE == "YUY2" || is_y )
        in_data <= vf_byte;                                       // payload : pixel data fetch from user
    else 
        in_data <= 8'h80;                                         // payload : U, V value for "MONO" image

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        in_valid <= 1'b0;
        is_y <= 1'b0;
        bcnt <= 0;
        pcnt <= 0;
        fid  <= '0;
        {vf_sof, vf_req} <= '0;
    end else begin
        {vf_sof, vf_req} <= '0;
        if(sof) begin
            in_valid <= 1'b1;
            bcnt <= 0;
        end else if(in_ready & in_valid) begin
            bcnt <= bcnt + 1;
            if( (bcnt+1) == psize ) begin
                in_valid <= 1'b0;
                if(~plast) begin
                    pcnt <= pcnt + 1;
                end else begin
                    pcnt <= 0;
                    fid  <= ~fid;
                end
            end
            if( (bcnt == 0) && (pcnt == 0) ) begin
                is_y <= 1'b0;
                vf_sof <= 1'b1;
            end
            if( (bcnt > 0) && ((bcnt+1) < psize) ) begin
                is_y <= ~is_y;
                vf_req <= (FRAME_TYPE == "YUY2" || !is_y);
            end
        end
    end




//-------------------------------------------------------------------------------------------------------------------------------------
// endpoint 00 (control endpoint) command response : UVC Video Probe and Commit Controls
//-------------------------------------------------------------------------------------------------------------------------------------
localparam logic [7:0] UVC_PROBE_COMMIT [34] = '{
    'h00, 'h00,                                                                                                    // bmHint
    'h01,                                                                                                          // bFormatIndex
    'h01,                                                                                                          // bFrameIndex
    dwFrameInterval[7:0]    , dwFrameInterval[15:8]    , dwFrameInterval[23:16]    , dwFrameInterval[31:24]    ,   // dwFrameInterval
    'h00, 'h00,                                                                                                    // wKeyFrameRate    : ignored by uncompressed video
    'h00, 'h00,                                                                                                    // wPFrameRate      : ignored by uncompressed video
    'h00, 'h00,                                                                                                    // wCompQuality     : ignored by uncompressed video
    'h00, 'h00,                                                                                                    // wCompWindowSize  : ignored by uncompressed video
    'h01, 'h00,                                                                                                    // wDelay (ms)
    dwMaxVideoFrameSize[7:0], dwMaxVideoFrameSize[15:8], dwMaxVideoFrameSize[23:16], dwMaxVideoFrameSize[31:24],   // dwMaxVideoFrameSize
    PacketSize[7:0], {6'h0, PacketSize[9:8]}, 'h00, 'h00,                                                          // dwMaxPayloadTransferSize
    'h80, 'h8D, 'h5B, 'h00,                                                                                        // dwClockFrequency
    'h03,                                                                                                          // bmFramingInfo
    'h00,                                                                                                          // bPreferedVersion
    'h00,                                                                                                          // bMinVersion
    'h00                                                                                                           // bMaxVersion
};

wire [63:0] ep00_setup_cmd;
wire [ 8:0] ep00_resp_idx;
reg  [ 7:0] ep00_resp;

always @ (posedge clk)
    if(ep00_setup_cmd[7:0] == 8'hA1 && ep00_setup_cmd[47:16] == 32'h_0001_0100 )
        ep00_resp <= UVC_PROBE_COMMIT[ep00_resp_idx];
    else
        ep00_resp <= '0;




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( '{  //  18 bytes available
        'h12, 'h01, 'h10, 'h01, 'hEF, 'h02, 'h01, 'h20, 'h9A, 'hFB, 'h9A, 'hFB, 'h00, 'h01, 'h01, 'h02, 'h00, 'h01
    } ),
    .DESCRIPTOR_STR1    ( '{  //  64 bytes available
        'h2C, 'h03, "g" , 'h00, "i" , 'h00, "t" , 'h00, "h" , 'h00, "u" , 'h00, "b" , 'h00, "." , 'h00, "c" , 'h00, "o" , 'h00, "m" , 'h00, "/" , 'h00, "W" , 'h00, "a" , 'h00, "n" , 'h00, "g" , 'h00, "X" , 'h00, "u" , 'h00, "a" , 'h00, "n" , 'h00, "9" , 'h00, "5" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_STR2    ( '{  //  64 bytes available
        'h2A, 'h03, "F" , 'h00, "P" , 'h00, "G" , 'h00, "A" , 'h00, "-" , 'h00, "U" , 'h00, "S" , 'h00, "B" , 'h00, "-" , 'h00, "v" , 'h00, "i" , 'h00, "d" , 'h00, "e" , 'h00, "o" , 'h00, "-" , 'h00, "i" , 'h00, "n" , 'h00, "p" , 'h00, "u" , 'h00, "t" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_CONFIG  ( '{  // 512 bytes available
        'h09, 'h02, 'h9A, 'h00, 'h02, 'h01, 'h00, 'h80, 'h64,                                // configuration descriptor, 2 interfaces
        'h08, 'h0B, 'h00, 'h02, 'h0E, 'h03, 'h00, 'h02,                                      // interface association descriptor, video interface collection
        'h09, 'h04, 'h00, 'h00, 'h00, 'h0E, 'h01, 'h00, 'h02,                                // interface descriptor, video, 1 endpoints
        'h0D, 'h24, 'h01, 'h10, 'h01, 'h20, 'h00, 'h80, 'h8D, 'h5B, 'h00, 'h01, 'h01,        // video control interface header descriptor
        'h0A, 'h24, 'h02, 'h01, 'h02, 'h02, 'h00, 'h00, 'h00, 'h00,                          // video control input terminal descriptor
        'h09, 'h24, 'h03, 'h02, 'h01, 'h01, 'h00, 'h01, 'h00,                                // video control output terminal descriptor
        'h09, 'h04, 'h01, 'h00, 'h00, 'h0E, 'h02, 'h00, 'h00,                                // interface descriptor, video, 0 endpoints
        'h0E, 'h24, 'h01, 'h01, 'h47, 'h00, 'h81, 'h00, 'h02, 'h00, 'h00, 'h00, 'h01, 'h00,  // video streaming interface input header descriptor
        'h1B, 'h24, 'h04, 'h01, 'h01, 'h59, 'h55, 'h59, 'h32, 'h00, 'h00, 'h10, 'h00, 'h80, 'h00, 'h00, 'hAA, 'h00, 'h38, 'h9B, 'h71, 'h10, 'h01, 'h00, 'h00, 'h00, 'h00,                    // video streaming uncompressed video format descriptor
        'h1E, 'h24, 'h05, 'h01, 'h02, wWidth[7:0], wWidth[15:8], wHeight[7:0], wHeight[15:8], 'h00, 'h00, 'h01, 'h00, 'h00, 'h00, 'h10, 'h00, 'h00, 'h00, 'h01, 'h00, dwFrameInterval[7:0], dwFrameInterval[15:8], dwFrameInterval[23:16], dwFrameInterval[31:24], 'h01, dwFrameInterval[7:0], dwFrameInterval[15:8], dwFrameInterval[23:16], dwFrameInterval[31:24],  // video streaming uncompressed video frame descriptor
        'h09, 'h04, 'h01, 'h01, 'h01, 'h0E, 'h02, 'h00, 'h00,                                // interface descriptor, video, 1 endpoints
        'h07, 'h05, 'h81, 'h01, PacketSize[7:0], {6'h0, PacketSize[9:8]}, 'h01,              // endpoint descriptor, 81
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .EP81_MAXPKTSIZE    ( PacketSize       ),
    .EP81_ISOCHRONOUS   ( 1                ),
    .DEBUG              ( DEBUG            )
) usbfs_core_i (
    .rstn               ( rstn             ),
    .clk                ( clk              ),
    .usb_dp_pull        ( usb_dp_pull      ),
    .usb_dp             ( usb_dp           ),
    .usb_dn             ( usb_dn           ),
    .usb_rstn           ( usb_rstn         ),
    .sot                (                  ),
    .sof                ( sof              ),
    .ep00_setup_cmd     ( ep00_setup_cmd   ),
    .ep00_resp_idx      ( ep00_resp_idx    ),
    .ep00_resp          ( ep00_resp        ),
    .ep81_data          ( in_data          ),
    .ep81_valid         ( in_valid         ),
    .ep81_ready         ( in_ready         ),
    .ep82_data          ( '0               ),
    .ep82_valid         ( '0               ),
    .ep82_ready         (                  ),
    .ep83_data          ( '0               ),
    .ep83_valid         ( '0               ),
    .ep83_ready         (                  ),
    .ep84_data          ( '0               ),
    .ep84_valid         ( '0               ),
    .ep84_ready         (                  ),
    .ep01_data          (                  ),
    .ep01_valid         (                  ),
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
