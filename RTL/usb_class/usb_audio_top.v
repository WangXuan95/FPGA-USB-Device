
//--------------------------------------------------------------------------------------------------------
// Module  : usb_audio_input_top
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A USB Full Speed (12Mbps) device, act as a USB Audio device.
//           Including an audio output device (host-to-device, such as a speaker),
//           and an audio input device (device-to-host, such as a microphone).
//--------------------------------------------------------------------------------------------------------

module usb_audio_top #(
    parameter DEBUG = "FALSE"         // whether to output USB debug info, "TRUE" or "FALSE"
) (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset), normally set to 1
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // USB reset output
    output wire        usb_rstn,      // 1: connected , 0: disconnected (when USB cable unplug, or when system reset (rstn=0))
    // user data : audio output (host-to-device, such as a speaker), and audio input (device-to-host, such as a microphone).
    output reg         audio_en,      // a 48kHz pulse, that is, audio_en=1 for 1 cycle every 1250 cycles. Note that 60MHz/48kHz=1250, where 60MHz is clk frequency.
    output reg  [15:0] audio_lo,      // left-channel  output: 16-bit signed integer, which will be valid when audio_en=1
    output reg  [15:0] audio_ro,      // right-channel output: 16-bit signed integer, which will be valid when audio_en=1
    input  wire [15:0] audio_li,      // left-channel  input : 16-bit signed integer, which will be sampled when audio_en=1
    input  wire [15:0] audio_ri,      // right-channel input : 16-bit signed integer, which will be sampled when audio_en=1
    // debug output info, only for USB developers, can be ignored for normally use. Please set DEBUG="TRUE" to enable these signals
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    // 
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);


initial audio_en = 1'b0;
initial audio_ro = 16'h0;
initial audio_lo = 16'h0;


wire       sof;

wire [7:0] out_data;      // data from USB device core (host-to-device)
wire       out_valid;

wire [7:0] in_data;       // data to USB device core (device-to-host)
reg        in_valid = 1'b0;
wire       in_ready;



//-------------------------------------------------------------------------------------------------------------------------------------
// generate a 48kHz pulse signal (audio_en). Note that 48kHz is the audio sample rate.
//-------------------------------------------------------------------------------------------------------------------------------------
reg  [10:0] cnt = 11'h0;             // a counter from 0 to 1249, since 60MHz/48kHz=1250, where 60MHz is clk frequency.
always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        cnt <= 11'h0;
        audio_en <= 1'b0;
    end else begin
        if (cnt < 11'd1249) begin
            cnt <= cnt + 11'd1;
            audio_en <= 1'b0;
        end else begin
            cnt <= 11'h0;
            audio_en <= 1'b1;
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio output (host-to-device) : convert byte-stream to 2-channel-16-bit-PCM
//-------------------------------------------------------------------------------------------------------------------------------------
reg  [ 1:0] o_pcm_cnt = 2'h0;    // count from 0 to 3
reg  [31:0] o_pcm     = 0;       // = { right-channel[15:0] , left-channel[15:0] }
reg         o_pcm_en  = 1'b0;    // when o_pcm_en=1, o_pcm valid
always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        o_pcm_cnt <= 2'h0;
        o_pcm     <= 0;
        o_pcm_en  <= 1'b0;
    end else begin
        o_pcm_en <= 1'b0;
        if (sof) begin                                // reset at the start of a new frame
            o_pcm_cnt <= 2'h0;
        end else if (out_valid) begin
            o_pcm_cnt <= o_pcm_cnt + 2'd1;
            o_pcm     <= {out_data, o_pcm[31:8]};     // shift on o_pcm from high-byte to low-byte
            o_pcm_en  <= (o_pcm_cnt == 2'd3);         // get a 32-bit PCM data every 4 bytes.
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio output (host-to-device) : buffer. The goal is to convert the USB-packet-burst data into a stable 48ksps output.
//-------------------------------------------------------------------------------------------------------------------------------------
reg [31:0] bufo [511 : 0];                    // may automatically synthesize to BRAM
reg [31:0] bufo_rd;
reg [ 9:0] bufo_wptr = 10'h0;
reg [ 9:0] bufo_rptr = 10'h0;
wire bufo_full_n  = (bufo_wptr != {~bufo_rptr[9], bufo_rptr[8:0]});
wire bufo_empty_n = (bufo_wptr != bufo_rptr);

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        bufo_wptr <= 10'h0;
    end else begin
        if (o_pcm_en & bufo_full_n)
            bufo_wptr <= bufo_wptr + 10'd1;
    end

always @ (posedge clk)
    if (o_pcm_en & bufo_full_n)
        bufo[bufo_wptr[8:0]] <= o_pcm;

always @ (posedge clk)
    bufo_rd <= bufo[bufo_rptr[8:0]];

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        bufo_rptr <= 10'h0;
        audio_ro <= 16'h0;
        audio_lo <= 16'h0;
    end else begin
        if (audio_en & bufo_empty_n) begin      // output a new audio data when 48kHz pulse and buffer is not empty, otherwise remain output audio data not change.
            bufo_rptr <= bufo_rptr + 10'd1;
            {audio_ro, audio_lo} <= bufo_rd;
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio input (device-to-host) : buffer. The goal is to convert the stable 48ksps audio input to the USB-packet-burst data.
//-------------------------------------------------------------------------------------------------------------------------------------
reg [31:0] bufi [511:0];             // may automatically synthesize to BRAM
reg [ 9:0] bufi_wptr = 10'h0;
reg [ 9:0] bufi_rptr = 10'h0;
reg [31:0] bufi_rd;
wire bufi_full_n  = (bufi_wptr != {~bufi_rptr[9], bufi_rptr[8:0]});
wire bufi_empty_n = (bufi_wptr != bufi_rptr);

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        bufi_wptr <= 10'h0;
    end else begin
        if (audio_en & bufi_full_n)
            bufi_wptr <= bufi_wptr + 10'd1;
    end

always @ (posedge clk)
    if (audio_en & bufi_full_n)
        bufi[bufi_wptr[8:0]] <= {audio_ri, audio_li};

always @ (posedge clk)
    bufi_rd <= bufi[bufi_rptr[8:0]];   // fetch data from buffer



//-------------------------------------------------------------------------------------------------------------------------------------
// audio input (device-to-host) : convert 2-channel-16-bit-PCM to byte stream
//-------------------------------------------------------------------------------------------------------------------------------------
reg [ 1:0] i_pcm_cnt = 2'h0;    // count from 0~3
reg [ 5:0] i_pkt_cnt = 6'h0;    // count from 0~47, since each USB packet carries 48 PCM data (2 channel * 2 byte * 48 = 192 bytes each packet)

always @ (posedge clk or negedge usb_rstn)
    if (~usb_rstn) begin
        bufi_rptr <= 10'h0;
        i_pcm_cnt <= 2'h0;
        i_pkt_cnt <= 6'h0;
        in_valid <= 1'b0;
    end else begin
        if (sof) begin
            i_pcm_cnt <= 2'h0;
            i_pkt_cnt <= 6'h0;
            in_valid <= 1'b1;
        end else if (in_ready) begin
            i_pcm_cnt <= i_pcm_cnt + 2'd1;
            if (i_pcm_cnt == 2'd3) begin
                if (i_pkt_cnt < 6'd47) begin
                    i_pkt_cnt <= i_pkt_cnt + 6'd1;
                    in_valid <= 1'b1;
                end else begin
                    in_valid <= 1'b0;
                end
                if (bufi_empty_n)
                    bufi_rptr <= bufi_rptr + 10'd1;
            end
        end
    end

assign in_data = bufi_rd[ (i_pcm_cnt*8) +: 8 ];




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( {  //  18 bytes available
        144'h12_01_10_01_00_00_00_20_9A_FB_9A_FB_00_01_01_02_00_01
    } ),
    .DESCRIPTOR_STR1    ( {  //  64 bytes available
        352'h2C_03_67_00_69_00_74_00_68_00_75_00_62_00_2e_00_63_00_6f_00_6d_00_2f_00_57_00_61_00_6e_00_67_00_58_00_75_00_61_00_6e_00_39_00_35_00,  // "github.com/WangXuan95"
        160'h0
    } ),
    .DESCRIPTOR_STR2    ( {  //  64 bytes available
        240'h1E_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_61_00_75_00_64_00_69_00_6f_00,                                            // "FPGA-USB-audio"
        272'h0
    } ),
    .DESCRIPTOR_STR3    ( {  //  64 bytes available
        288'h24_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_61_00_75_00_64_00_69_00_6f_00_2d_00_69_00_6e_00,                          // "FPGA-USB-audio-in"
        224'h0
    } ),
    .DESCRIPTOR_STR4    ( {  //  64 bytes available
        304'h26_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_61_00_75_00_64_00_69_00_6f_00_2d_00_6F_00_75_00_74_00,                    // "FPGA-USB-audio-out"
        208'h0
    } ),
    .DESCRIPTOR_CONFIG  ( {  // 512 bytes available
        72'h09_02_AE_00_03_01_00_80_64,            // configuration descriptor                    // ***bug fixed at 20230527. The previous version puts microphone and speaker into different compensite device, where the microphone cannot be recognized by Linux.
        72'h09_04_00_00_00_01_01_00_02,            // interface descriptor, audio control (AC)
        80'h0A_24_01_00_01_34_00_02_01_02,         // AC interface header descriptor
        96'h0C_24_02_01_01_02_00_02_03_00_00_00,   // AC Input  terminal descriptor, microphone, ID=0x01, 2channel (stereo)
        72'h09_24_03_02_01_01_03_01_03,            // AC Output terminal descriptor, USB-stream, ID=0x02, source from ID=0x01
        96'h0C_24_02_03_01_01_02_02_03_00_00_04,   // AC Input  terminal descriptor, USB-stream, ID=0x03, 2channel (stereo)
        72'h09_24_03_04_01_03_00_03_00,            // AC Output terminal descriptor, speaker   , ID=0x04, source from ID=0x03
        72'h09_04_01_00_00_01_02_00_03,            // interface descriptor
        72'h09_04_01_01_01_01_02_00_03,            // interface descriptor, audio streaming (AS)
        56'h07_24_01_02_01_01_00,                  // AS interface descriptor, link to terminal ID=0x02, interface delay=0x01, PCM format
        88'h0B_24_02_01_02_02_10_01_80_BB_00,      // AS format type descriptor, 2channel (stereo), 16bit 48000Hz
        72'h09_05_82_01_C0_00_01_00_00,            // endpoint descriptor, endpoint 0x82, 0xC0=192=48*2*2 bytes per packet, one packet per frame (1frame = 1ms)
        56'h07_25_01_00_00_00_00,                  // audio data endpoint descriptor
        72'h09_04_02_00_00_01_02_00_04,            // interface descriptor
        72'h09_04_02_01_01_01_02_00_04,            // interface descriptor, audio streaming (AS)
        56'h07_24_01_03_01_01_00,                  // AS interface descriptor, link to terminal ID=0x03, interface delay=0x01, PCM format
        88'h0B_24_02_01_02_02_10_01_80_BB_00,      // AS format type descriptor, 2channel (stereo), 16bit 48000Hz
        72'h09_05_01_01_C0_00_01_00_00,            // endpoint descriptor, endpoint 0x01, 0xC0=192=48*2*2 bytes per packet, one packet per frame (1frame = 1ms)
        56'h07_25_01_01_00_00_00,                  // audio data endpoint descriptor
        2704'h0
    } ),
    .EP82_MAXPKTSIZE    ( 10'hC0           ),    // USB packet length = 192 bytes = 2 channel * 2 byte * 48 PCM datas
    .EP82_ISOCHRONOUS   ( 1                ),
    .EP01_ISOCHRONOUS   ( 1                ),
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
    .ep00_setup_cmd     (                  ),
    .ep00_resp_idx      (                  ),
    .ep00_resp          ( 8'h0             ),
    .ep81_data          ( 8'h0             ),
    .ep81_valid         ( 1'b0             ),
    .ep81_ready         (                  ),
    .ep82_data          ( in_data          ),
    .ep82_valid         ( in_valid         ),
    .ep82_ready         ( in_ready         ),
    .ep83_data          ( 8'h0             ),
    .ep83_valid         ( 1'b0             ),
    .ep83_ready         (                  ),
    .ep84_data          ( 8'h0             ),
    .ep84_valid         ( 1'b0             ),
    .ep84_ready         (                  ),
    .ep01_data          ( out_data         ),
    .ep01_valid         ( out_valid        ),
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
