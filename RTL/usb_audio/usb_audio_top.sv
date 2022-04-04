
//--------------------------------------------------------------------------------------------------------
// Module  : usb_audio_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: A USB Full Speed (12Mbps) device, act as a USB Audio device (Audio output only)
//--------------------------------------------------------------------------------------------------------

module usb_audio_top (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset), normally set to 1
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // Audio 48kHz 16bit 2 channel
    output reg [15:0]  audio_L_ch,    // connect to Audio DAC left channel
    output reg [15:0]  audio_R_ch     // connect to Audio DAC right channel
);

//-------------------------------------------------------------------------------------------------------------------------------------
// descriptor ROM and ROM-read logic
//-------------------------------------------------------------------------------------------------------------------------------------
wire [7:0] descriptor_rom [1024] = '{
    // device descriptor                                                        offset=0x000(should fixed)  available-space=0x020
    8'h12, 8'h01, 8'h10, 8'h01, 8'h00, 8'h00, 8'h00, 8'h20, 8'h08, 8'h19, 8'h70, 8'h20, 8'h31, 8'h00, 8'h01, 8'h02, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 0 (supported languages)                                offset=0x020(should fixed)  available-space=0x020
    8'h04, 8'h03, 8'h09, 8'h04, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 1 (manufacturer, if any)                               offset=0x040(should fixed)  available-space=0x040
    8'h2C, 8'h03, "g"  , 8'h00, "i"  , 8'h00, "t"  , 8'h00, "h"  , 8'h00, "u"  , 8'h00, "b"  , 8'h00, "."  , 8'h00, "c"  , 8'h00, "o"  , 8'h00, "m"  , 8'h00, "/"  , 8'h00, "W"  , 8'h00, "a"  , 8'h00, "n"  , 8'h00, "g"  , 8'h00, "X"  , 8'h00, "u"  , 8'h00, "a"  , 8'h00, "n"  , 8'h00, "9"  , 8'h00, "5"  , 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 2 (product, if any)                                    offset=0x080(should fixed)  available-space=0x040
    8'h1A, 8'h03, "F"  , 8'h00, "P"  , 8'h00, "G"  , 8'h00, "A"  , 8'h00, " "  , 8'h00, "U"  , 8'h00, "S"  , 8'h00, "B"  , 8'h00, "-"  , 8'h00, "A"  , 8'h00, "u"  , 8'h00, "d"  , 8'h00, "i"  , 8'h00, "o"  , 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // string descriptor 3 (serial-number, if any)                              offset=0x0C0(should fixed)  available-space=0x040
    8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
    
    // configuration descriptor set                                             offset=0x100(should fixed)  available-space=0x200=512
    8'h09,8'h02,8'd110,8'h00,8'h02,8'h01,8'h00,8'h80,8'hC8,//配置描述符

    8'h09,8'h04,8'h00,8'h00,8'h00,8'h01,8'h01,8'h00,8'h00,//接口描述符，audio，audio control

    8'h09,8'h24,8'h01,8'h00,8'h01,8'h28,8'h00,8'h01,8'h01,//Audio Control Interface Header Descriptor
    8'h0C,8'h24,8'h02,8'h01,8'h01,8'h01,8'h00,8'h02,8'h03,8'h00,8'h00,8'h00,//Audio Control Input Terminal Descriptor
    8'h0A,8'h24,8'h06,8'h02,8'h01,8'h01,8'h03,8'h00,8'h00,8'h00,// Audio Control Feature Unit Descriptor
    8'h09,8'h24,8'h03,8'h03,8'h01,8'h03,8'h00,8'h02,8'h00,//Audio Control Output Terminal Descriptor

    8'h09,8'h04,8'h01,8'h00,8'h00,8'h01,8'h02,8'h00,8'h00,//Interface Descriptor
    8'h09,8'h04,8'h01,8'h01,8'h01,8'h01,8'h02,8'h00,8'h00,//Interface Descriptor
    8'h07,8'h24,8'h01,8'h01,8'h01,8'h01,8'h00,//Audio Streaming Interface Descriptor
    8'h0B,8'h24,8'h02,8'h01,8'h02,8'h02,8'h10,8'h01,8'h80,8'hBB,8'h00,//Audio Streaming Format Type Descriptor
    8'h09,8'h05,8'h01,8'h01,8'hC0,8'h00,8'h01,8'h00,8'h00,//Endpoint Descriptor
    8'h07,8'h25,8'h01,8'h00,8'h00,8'h00,8'h00,//Audio Data Endpoint Descriptor
//8'h00
    8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,//8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,//9
    // HID descriptor (if any)                                                 offset=0x300(should fixed)  available-space=0x100
    8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00
};
wire [ 9:0] desc_addr;
reg  [ 7:0] desc_data = '0;
always @ (posedge clk) desc_data <= descriptor_rom[desc_addr];


//-------------------------------------------------------------------------------------------------------------------------------------
// USB Audio PCM (for host-to-device), 双缓冲空间double bufsize[15:0] =2 * 48000Hz * 0.001s * 2(Ch) * 2(16b/8b) =2*192B =2*96(16b)
//-------------------------------------------------------------------------------------------------------------------------------------
`define buf_len 96
wire [7:0]recv_data;
wire recv_valid;
reg [10:0]clk48_cnt;//clk div
reg audio_en;//48kHz频率输出音频
reg [6:0]audio_index;//音频索引


reg [15:0]audio_buf0[`buf_len-1:0];//buf0
reg [6:0]bindex0;//buf0索引buf0 index
reg [15:0]audio_buf1[`buf_len-1:0];//buf1
reg [6:0]bindex1;//buf1索引buf1 index
reg ppsta,ppsta_r;//乒乓操作状态寄存器ping-pong state reg
//ppsta=0, usb -> audio_buf0, audio_buf1 -> voice
//ppsta=1, usb -> audio_buf1, audio_buf0 -> voice

reg [7:0]pcm_lsb;//reg pcm[7:0]
reg pcm_valid;// 当低位被缓存，pcm_valid==1

//8b usb data -> 16b PCM signed
always @ (posedge clk or negedge usb_rstn) 
    if(~usb_rstn) begin
        pcm_valid <= 1'b0;
        pcm_lsb <= '0;
    end else begin
        if(recv_valid) begin
            pcm_valid<=~pcm_valid;   //高低位切换
            pcm_lsb<=recv_data;
        end
    end

//usb -> audio_buf
always @ (posedge clk or negedge usb_rstn) 
    if(~usb_rstn) begin
        ppsta <= 1'b0;
        bindex0 <= '0;
        bindex1 <= '0;
    end else begin
        if(ppsta) begin    //buf1
            if(recv_valid && pcm_valid) begin   //收到数据且低位被缓存
                audio_buf1[bindex1]<={~recv_data[7],recv_data[6:0],pcm_lsb};   //16b signed -> 16b unsigned
                if(bindex1==`buf_len-1) begin   //写满
                    bindex1<= '0;
                    ppsta<=~ppsta;   // 切换
                end else begin
                    bindex1<=bindex1+1;   //还没满
                end
            end
        end else begin //buf0
            if(recv_valid && pcm_valid) begin
                audio_buf0[bindex0]<={~recv_data[7],recv_data[6:0],pcm_lsb};
                if(bindex0==`buf_len-1) begin
                    bindex0<= '0;
                    ppsta<=~ppsta;
                end else begin
                    bindex0<=bindex0+1;
                end
            end
        end
    end

//48kHz clk en
always @ (posedge clk or negedge usb_rstn) 
    if(~usb_rstn) begin
        clk48_cnt <= '0;
        audio_en <= 1'b0;
        ppsta_r <= 1'b0;
    end else begin
        ppsta_r <= ppsta;
        if((clk48_cnt==60_000_000/48_000-1) || (ppsta_r^ppsta)) begin//计数溢出或乒乓切换 counter overflow or switch buf
            clk48_cnt <= '0;
        end else begin 
            clk48_cnt <= clk48_cnt+1;
        end
        if(clk48_cnt==60_000_000/48_000/2) begin  // 将触发值放于中央，保证可靠性
            audio_en <= 1'b1;
        end else begin 
            audio_en <= 1'b0;
        end
    end

//audio output
always @ (posedge clk or negedge usb_rstn) 
    if(~usb_rstn) begin
        audio_L_ch<= '0;
        audio_R_ch<= '0;
        audio_index<= '0;
    end else begin
        if(ppsta_r^ppsta) begin
            audio_index<= '0;   // if switch buf
        end else begin
            if(audio_en) begin  // 48kHz speed output
                audio_index<= audio_index+2;
                if(ppsta) begin  // buf0
                    audio_L_ch<= audio_buf0[audio_index];
                    audio_R_ch<= audio_buf0[audio_index+1];
                end else begin   // buf1
                    audio_L_ch<= audio_buf1[audio_index];
                    audio_R_ch<= audio_buf1[audio_index+1];
                end
            end
        end
    end
//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .ENDP_00_MAXPKTSIZE ( 10'd32        ),
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
    .in_data         (                  ),
    .in_valid        (                  ),
    .in_ready        (                  )
);

endmodule
