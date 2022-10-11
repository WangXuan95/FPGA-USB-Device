
//--------------------------------------------------------------------------------------------------------
// Module  : usb_audio_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
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
    output reg         audio_en,      // a 48kHz pulse, that is, audio_en=1 for 1 cycle every 1250 cycle. Note that 60MHz/48kHz=1250, where 60MHz is clk frequency.
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
initial {audio_ro, audio_lo} = '0;


wire       sof;

wire [7:0] out_data;      // data from USB device core (host-to-device)
wire       out_valid;

wire [7:0] in_data;       // data to USB device core (device-to-host)
reg        in_valid = '0;
wire       in_ready;



//-------------------------------------------------------------------------------------------------------------------------------------
// generate a 48kHz pulse signal (audio_en). Note that 48kHz is the audio sample rate.
//-------------------------------------------------------------------------------------------------------------------------------------
reg  [10:0] cnt = '0;             // a counter from 0 to 1249, since 60MHz/48kHz=1250, where 60MHz is clk frequency.
always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        cnt <= '0;
        audio_en <= '0;
    end else begin
        if(cnt < 11'd1249) begin
            cnt <= cnt + 11'd1;
            audio_en <= 1'b0;
        end else begin
            cnt <= '0;
            audio_en <= 1'b1;
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio output (host-to-device) : convert byte-stream to 2-channel-16-bit-PCM
//-------------------------------------------------------------------------------------------------------------------------------------
reg  [ 1:0] o_pcm_cnt = '0;      // count from 0 to 3
reg  [31:0] o_pcm     = '0;      // = { right-channel[15:0] , left-channel[15:0] }
reg         o_pcm_en  = '0;      // when o_pcm_en=1, o_pcm valid
always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        o_pcm_cnt <= '0;
        o_pcm     <= '0;
        o_pcm_en  <= '0;
    end else begin
        o_pcm_en <= '0;
        if(sof) begin                                 // reset at the start of a new frame
            o_pcm_cnt <= '0;
        end else if(out_valid) begin
            o_pcm_cnt <= o_pcm_cnt + 2'd1;
            o_pcm     <= {out_data, o_pcm[31:8]};     // shift on o_pcm from high-byte to low-byte
            o_pcm_en  <= (o_pcm_cnt == 2'd3);         // get a 32-bit PCM data every 4 bytes.
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio output (host-to-device) : buffer. The goal is to convert the USB-packet-burst data into a stable 48ksps output.
//-------------------------------------------------------------------------------------------------------------------------------------
reg [31:0] bufo [512] = '{512{'0}};    // may automatically synthesize to BRAM
reg [31:0] bufo_rd;
reg [ 9:0] bufo_wptr = '0;
reg [ 9:0] bufo_rptr = '0;
wire bufo_full_n  = bufo_wptr != {~bufo_rptr[9], bufo_rptr[8:0]};
wire bufo_empty_n = bufo_wptr != bufo_rptr;

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        bufo_wptr <= '0;
    end else begin
        if(o_pcm_en & bufo_full_n)
            bufo_wptr <= bufo_wptr + 10'd1;
    end

always @ (posedge clk)
    if(o_pcm_en & bufo_full_n)
        bufo[bufo_wptr[8:0]] <= o_pcm;

always @ (posedge clk)
    bufo_rd <= bufo[bufo_rptr[8:0]];

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        bufo_rptr <= '0;
        {audio_ro, audio_lo} <= '0;
    end else begin
        if(audio_en & bufo_empty_n) begin      // output a new audio data when 48kHz pulse and buffer is not empty, otherwise remain output audio data not change.
            bufo_rptr <= bufo_rptr + 10'd1;
            {audio_ro, audio_lo} <= bufo_rd;
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// audio input (device-to-host) : buffer. The goal is to convert the stable 48ksps audio input to the USB-packet-burst data.
//-------------------------------------------------------------------------------------------------------------------------------------
reg [31:0] bufi [512] = '{512{'0}};    // may automatically synthesize to BRAM
reg [ 9:0] bufi_wptr = '0;
reg [ 9:0] bufi_rptr = '0;
reg [31:0] bufi_rd;
wire bufi_full_n  = bufi_wptr != {~bufi_rptr[9], bufi_rptr[8:0]};
wire bufi_empty_n = bufi_wptr != bufi_rptr;

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        bufi_wptr <= '0;
    end else begin
        if(audio_en & bufi_full_n)
            bufi_wptr <= bufi_wptr + 10'd1;
    end

always @ (posedge clk)
    if(audio_en & bufi_full_n)
        bufi[bufi_wptr[8:0]] <= {audio_ri, audio_li};

always @ (posedge clk)
    bufi_rd <= bufi[bufi_rptr[8:0]];   // fetch data from buffer



//-------------------------------------------------------------------------------------------------------------------------------------
// audio input (device-to-host) : convert 2-channel-16-bit-PCM to byte stream
//-------------------------------------------------------------------------------------------------------------------------------------
reg [ 1:0] i_pcm_cnt = '0;    // count from 0~3
reg [ 5:0] i_pkt_cnt = '0;    // count from 0~47, since each USB packet carries 48 PCM data (2 channel * 2 byte * 48 = 192 bytes each packet)

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        bufi_rptr <= '0;
        i_pcm_cnt <= '0;
        i_pkt_cnt <= '0;
        in_valid <= '0;
    end else begin
        if(sof) begin
            i_pcm_cnt <= '0;
            i_pkt_cnt <= '0;
            in_valid <= 1'b1;
        end else if(in_ready) begin
            i_pcm_cnt <= i_pcm_cnt + 2'd1;
            if(i_pcm_cnt == 2'd3) begin
                if(i_pkt_cnt < 6'd47) begin
                    i_pkt_cnt <= i_pkt_cnt + 6'd1;
                    in_valid <= 1'b1;
                end else begin
                    in_valid <= 1'b0;
                end
                if(bufi_empty_n)
                    bufi_rptr <= bufi_rptr + 10'd1;
            end
        end
    end

assign in_data = bufi_rd[ (i_pcm_cnt*8) +: 8 ];




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
        'h1E, 'h03, "F" , 'h00, "P" , 'h00, "G" , 'h00, "A" , 'h00, "-" , 'h00, "U" , 'h00, "S" , 'h00, "B" , 'h00, "-" , 'h00, "a" , 'h00, "u" , 'h00, "d" , 'h00, "i" , 'h00, "o" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_STR4    ( '{  //  64 bytes available
        'h2A, 'h03, "F" , 'h00, "P" , 'h00, "G" , 'h00, "A" , 'h00, "-" , 'h00, "U" , 'h00, "S" , 'h00, "B" , 'h00, "-" , 'h00, "a" , 'h00, "u" , 'h00, "d" , 'h00, "i" , 'h00, "o" , 'h00, "-" , 'h00, "i" , 'h00, "n" , 'h00, "p" , 'h00, "u" , 'h00, "t" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_CONFIG  ( '{  // 512 bytes available
        'h09, 'h02, 'hCF, 'h00, 'h04, 'h01, 'h00, 'h80, 'h64,                     // configuration descriptor
        'h08, 'h0B, 'h00, 'h02, 'h01, 'h02, 'h00, 'h02,                           // interface association descriptor : audio output
        'h09, 'h04, 'h00, 'h00, 'h00, 'h01, 'h01, 'h00, 'h02,                     // interface descriptor, audio control (AC)
        'h09, 'h24, 'h01, 'h00, 'h01, 'h1E, 'h00, 'h01, 'h01,                     // AC interface header descriptor
        'h0C, 'h24, 'h02, 'h01, 'h01, 'h01, 'h03, 'h02, 'h03, 'h00, 'h00, 'h00,   // AC Input  terminal descriptor, USB-stream, ID=0x01, 2channel
        'h09, 'h24, 'h03, 'h03, 'h01, 'h03, 'h01, 'h01, 'h00,                     // AC Output terminal descriptor, speaker   , ID=0x03, source from ID=0x01
        'h09, 'h04, 'h01, 'h00, 'h00, 'h01, 'h02, 'h00, 'h00,                     // interface descriptor
        'h09, 'h04, 'h01, 'h01, 'h01, 'h01, 'h02, 'h00, 'h00,                     // interface descriptor, audio streaming (AS)
        'h07, 'h24, 'h01, 'h01, 'h01, 'h01, 'h00,                                 // AS interface descriptor, PCM
        'h0B, 'h24, 'h02, 'h01, 'h02, 'h02, 'h10, 'h01, 'h80, 'hBB, 'h00,         // AS format type descriptor, 2channel 16bit 48ksps
        'h09, 'h05, 'h01, 'h01, 'hC0, 'h00, 'h01, 'h00, 'h00,                     // endpoint descriptor, 0xC0=192=48*2*2 bytes per frame (1frame = 1ms)
        'h07, 'h25, 'h01, 'h01, 'h00, 'h00, 'h00,                                 // audio data endpoint descriptor
        'h08, 'h0B, 'h02, 'h02, 'h01, 'h02, 'h00, 'h04,                           // interface association descriptor : audio input
        'h09, 'h04, 'h02, 'h00, 'h00, 'h01, 'h01, 'h00, 'h04,                     // interface descriptor, audio control (AC)
        'h09, 'h24, 'h01, 'h00, 'h01, 'h1E, 'h00, 'h01, 'h03,                     // AC interface header descriptor
        'h0C, 'h24, 'h02, 'h01, 'h01, 'h02, 'h03, 'h02, 'h03, 'h00, 'h00, 'h00,   // AC Input  terminal descriptor, microphone, ID=0x04, 2channel
        'h09, 'h24, 'h03, 'h03, 'h01, 'h01, 'h01, 'h01, 'h00,                     // AC Output terminal descriptor, USB-stream, ID=0x02, source from ID=0x04
        'h09, 'h04, 'h03, 'h00, 'h00, 'h01, 'h02, 'h00, 'h00,                     // interface descriptor
        'h09, 'h04, 'h03, 'h01, 'h01, 'h01, 'h02, 'h00, 'h00,                     // interface descriptor, audio streaming (AS)
        'h07, 'h24, 'h01, 'h03, 'h01, 'h01, 'h00,                                 // AS interface descriptor, PCM
        'h0B, 'h24, 'h02, 'h01, 'h02, 'h02, 'h10, 'h01, 'h80, 'hBB, 'h00,         // AS format type descriptor, 2channel 16bit 48ksps
        'h09, 'h05, 'h82, 'h01, 'hC0, 'h00, 'h01, 'h00, 'h00,                     // endpoint descriptor, 0xC0=192=48*2*2 bytes per frame (1frame = 1ms)
        'h07, 'h25, 'h01, 'h01, 'h00, 'h00, 'h00,                                 // audio data endpoint descriptor
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
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
    .ep00_resp          ( '0               ),
    .ep81_data          ( '0               ),
    .ep81_valid         ( '0               ),
    .ep81_ready         (                  ),
    .ep82_data          ( in_data          ),
    .ep82_valid         ( in_valid         ),
    .ep82_ready         ( in_ready         ),
    .ep83_data          ( '0               ),
    .ep83_valid         ( '0               ),
    .ep83_ready         (                  ),
    .ep84_data          ( '0               ),
    .ep84_valid         ( '0               ),
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
