
//--------------------------------------------------------------------------------------------------------
// Module  : usb_camera_top
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
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
    parameter          FRAME_TYPE = "YUY2",    // "MONO" or "YUY2"
    parameter   [13:0] FRAME_W    = 14'd320,   // video-frame width  in pixels, must be a even number
    parameter   [13:0] FRAME_H    = 14'd240,   // video-frame height in pixels, must be a even number
    parameter          DEBUG      = "FALSE"    // whether to output USB debug info, "TRUE" or "FALSE"
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
localparam [31:0] FramePixelCount     = {16'h0,wHeight} * {16'h0,wWidth};
localparam [31:0] dwMaxVideoFrameSize = FramePixelCount * 2;                                                                            // 2 bytes for each pixel
localparam [ 9:0] PacketSize          = 10'd802;                                                                                        // USB-packet = 2 byte header + PayloadSize bytes of pixel datas
localparam [31:0] PayloadSize         = {22'h0, PacketSize} - 2;                                                                        // each USB-packet contains PayloadSize bytes (exclude the header)
localparam [31:0] FramePacketCount    = (dwMaxVideoFrameSize + PayloadSize - 1)  / PayloadSize;                                         // USB-packet count of one video-frame
localparam [31:0] LastPayloadSize     = (dwMaxVideoFrameSize % PayloadSize == 0) ? PayloadSize : (dwMaxVideoFrameSize % PayloadSize);   // size of the last USB-packet of one video-frame (exclude the header)
localparam [31:0] LastPacketSize      = LastPayloadSize + 2;                                                                            // size of the last USB-packet of one video-frame (include the header)
localparam [31:0] FrameInterval_ms    = FramePacketCount;                                                                               // video-frame interval (unit: 1ms), Note that USB send 1 USB-packet in each USB-frame (1ms), thus FrameInterval_ms = FramePacketCount
localparam [31:0] dwFrameInterval     = FrameInterval_ms * 10000;                                                                       // video-frame interval (unit: 100ns)


function  [15:0] toLittleEndian_2byte;
    input [15:0] value;
begin
    toLittleEndian_2byte = {value[7:0], value[15:8]};
end
endfunction


function  [31:0] toLittleEndian_4byte;
    input [31:0] value;
begin
    toLittleEndian_4byte = {value[7:0], value[15:8], value[23:16], value[31:24]};
end
endfunction



//-------------------------------------------------------------------------------------------------------------------------------------
// USB-packet generation for video transmitting
//-------------------------------------------------------------------------------------------------------------------------------------

initial vf_sof = 1'b0;
initial vf_req = 1'b0;

wire        sof;                                                    // this is a start of USB-frame, not video-frame

wire        in_ready;
reg         in_valid = 1'b0;
reg  [ 7:0] in_data  = 8'h0;

reg         is_y  = 1'b0;
reg  [31:0] bcnt  = 0;                                              // byte count in one USB-packet (include packet header bytes)
reg  [31:0] pcnt  = 0;                                              // USB-packet count in one video-frame
wire        plast = ((pcnt + 1) >= FramePacketCount);               // whether it is the last USB-packet of a video-frame
wire [31:0] psize = plast ? LastPacketSize : ({22'h0, PacketSize}); // size of the current USB-packet to send
reg         fid   = 1'b0;                                           // toggle when each video-frame transmit done

always @ (posedge clk)
    if      ( bcnt == 0 )
        in_data <= 8'h02;                                           // HLE (header length) = 2
    else if ( bcnt == 1 )
        in_data <= {6'b100000, plast, fid};                         // BFH[0]
    else if ( (FRAME_TYPE == "YUY2") || is_y )
        in_data <= vf_byte;                                         // payload : pixel data fetch from user
    else 
        in_data <= 8'h80;                                           // payload : U, V value for "MONO" image

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        in_valid <= 1'b0;
        is_y <= 1'b0;
        bcnt <= 0;
        pcnt <= 0;
        fid  <= 1'b0;
        vf_sof <= 1'b0;
        vf_req <= 1'b0;
    end else begin
        vf_sof <= 1'b0;
        vf_req <= 1'b0;
        if (sof) begin
            in_valid <= 1'b1;
            bcnt <= 0;
        end else if (in_ready & in_valid) begin
            bcnt <= bcnt + 1;
            if ( (bcnt+1) == psize ) begin
                in_valid <= 1'b0;
                if (~plast) begin
                    pcnt <= pcnt + 1;
                end else begin
                    pcnt <= 0;
                    fid  <= ~fid;
                end
            end
            if ( (bcnt == 0) && (pcnt == 0) ) begin
                is_y <= 1'b0;
                vf_sof <= 1'b1;
            end
            if ( (bcnt > 0) && ((bcnt+1) < psize) ) begin
                is_y <= ~is_y;
                vf_req <= (FRAME_TYPE == "YUY2" || !is_y);
            end
        end
    end




//-------------------------------------------------------------------------------------------------------------------------------------
// endpoint 00 (control endpoint) command response : UVC Video Probe and Commit Controls
//-------------------------------------------------------------------------------------------------------------------------------------
localparam [34*8-1:0] UVC_PROBE_COMMIT = {
    16'h00_00,                                                     // bmHint
     8'h01,                                                        // bFormatIndex
     8'h01,                                                        // bFrameIndex
    toLittleEndian_4byte(dwFrameInterval),                         // dwFrameInterval
    16'h00_00,                                                     // wKeyFrameRate    : ignored by uncompressed video
    16'h00_00,                                                     // wPFrameRate      : ignored by uncompressed video
    16'h00_00,                                                     // wCompQuality     : ignored by uncompressed video
    16'h00_00,                                                     // wCompWindowSize  : ignored by uncompressed video
    16'h01_00,                                                     // wDelay (ms)
    toLittleEndian_4byte(dwMaxVideoFrameSize),                     // dwMaxVideoFrameSize
    toLittleEndian_4byte({22'h0, PacketSize}),                     // dwMaxPayloadTransferSize
    32'h80_8D_5B_00,                                               // dwClockFrequency
     8'h03,                                                        // bmFramingInfo
     8'h00,                                                        // bPreferedVersion
     8'h00,                                                        // bMinVersion
     8'h00                                                         // bMaxVersion
};

wire [63:0] ep00_setup_cmd;
wire [ 8:0] ep00_resp_idx;
reg  [ 7:0] ep00_resp;

always @ (posedge clk)
    if ((ep00_setup_cmd[7:0] == 8'hA1) && (ep00_setup_cmd[47:16] == 32'h0001_0100))
        ep00_resp <= UVC_PROBE_COMMIT[ (34 - 1 - ep00_resp_idx) * 8 +: 8 ];
    else
        ep00_resp <= 8'h0;




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( {  //  18 bytes available
        144'h12_01_10_01_EF_02_01_20_9A_FB_9A_FB_00_01_01_02_00_01
    } ),
    .DESCRIPTOR_STR1    ( {  //  64 bytes available
        352'h2C_03_67_00_69_00_74_00_68_00_75_00_62_00_2e_00_63_00_6f_00_6d_00_2f_00_57_00_61_00_6e_00_67_00_58_00_75_00_61_00_6e_00_39_00_35_00,  // "github.com/WangXuan95"
        160'h0
    } ),
    .DESCRIPTOR_STR2    ( {  //  64 bytes available
        336'h2A_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_76_00_69_00_64_00_65_00_6f_00_2d_00_69_00_6e_00_70_00_75_00_74_00,        // "FPGA-USB-video-input"
        176'h0
    } ),
    .DESCRIPTOR_CONFIG  ( {  // 512 bytes available
         72'h09_02_9A_00_02_01_00_80_64,                                                         // configuration descriptor, 2 interfaces
         64'h08_0B_00_02_0E_03_00_02,                                                            // interface association descriptor, video interface collection
         72'h09_04_00_00_00_0E_01_00_02,                                                         // interface descriptor, video, 1 endpoints
        104'h0D_24_01_10_01_20_00_80_8D_5B_00_01_01,                                             // video control interface header descriptor
         80'h0A_24_02_01_02_02_00_00_00_00,                                                      // video control input terminal descriptor
         72'h09_24_03_02_01_01_00_01_00,                                                         // video control output terminal descriptor
         72'h09_04_01_00_00_0E_02_00_00,                                                         // interface descriptor, video, 0 endpoints
        112'h0E_24_01_01_47_00_81_00_02_00_00_00_01_00,                                          // video streaming interface input header descriptor
        216'h1B_24_04_01_01_59_55_59_32_00_00_10_00_80_00_00_AA_00_38_9B_71_10_01_00_00_00_00,   // video streaming uncompressed video format descriptor
         40'h1E_24_05_01_02, toLittleEndian_2byte(wWidth), toLittleEndian_2byte(wHeight), 96'h00_00_01_00_00_00_10_00_00_00_01_00, toLittleEndian_4byte(dwFrameInterval), 8'h01, toLittleEndian_4byte(dwFrameInterval),  // video streaming uncompressed video frame descriptor
         72'h09_04_01_01_01_0E_02_00_00,                                                         // interface descriptor, video, 1 endpoints
         32'h07_05_81_01, toLittleEndian_2byte({6'h0, PacketSize}), 8'h01,                       // endpoint descriptor, 81
        2864'h0
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
    .ep82_data          ( 8'h0             ),
    .ep82_valid         ( 1'b0             ),
    .ep82_ready         (                  ),
    .ep83_data          ( 8'h0             ),
    .ep83_valid         ( 1'b0             ),
    .ep83_ready         (                  ),
    .ep84_data          ( 8'h0             ),
    .ep84_valid         ( 1'b0             ),
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
