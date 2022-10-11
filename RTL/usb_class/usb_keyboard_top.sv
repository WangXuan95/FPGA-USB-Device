
//--------------------------------------------------------------------------------------------------------
// Module  : usb_keyboard_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: A USB Full Speed (12Mbps) device, act as a USB HID keyboard
//--------------------------------------------------------------------------------------------------------

module usb_keyboard_top #(
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
    // HID keyboard press signal
    input  wire [15:0] key_value,     // Indicates which key to press, NOT ASCII code! see https://www.usb.org/sites/default/files/hut1_21_0.pdf section 10.
    input  wire        key_request,   // when key_request=1 pulses, a key is pressed.
    // debug output info, only for USB developers, can be ignored for normally use. Please set DEBUG="TRUE" to enable these signals
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    // 
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);



//-------------------------------------------------------------------------------------------------------------------------------------
// HID keyboard IN data packet process
//-------------------------------------------------------------------------------------------------------------------------------------
reg  [23:0] in_data = '0;
reg         in_valid = '0;
reg  [ 4:0] in_cnt = '0;
wire        in_ready;

always @ (posedge clk or negedge usb_rstn)
    if(~usb_rstn) begin
        in_data <= '0;
        in_valid <= 1'b0;
        in_cnt <= '0;
    end else begin
        if(in_cnt == 5'd0) begin
            in_data <= {key_value[7:0], 8'h0, key_value[15:8]};
            if(key_request) begin
                in_valid <= 1'b1;
                in_cnt <= 5'd1;
            end
        end else if(in_cnt < 5'd17) begin
            if(in_ready) begin
                in_data <= {8'h0, in_data[23:8]};
                in_cnt <= in_cnt + 5'd1;
            end
        end else begin
            in_valid <= 1'b0;
            in_cnt <= '0;
        end
    end




//-------------------------------------------------------------------------------------------------------------------------------------
// endpoint 00 (control endpoint) command response : HID descriptor
//-------------------------------------------------------------------------------------------------------------------------------------
wire [63:0] ep00_setup_cmd;
wire [ 8:0] ep00_resp_idx;
reg  [ 7:0] ep00_resp;

localparam logic [7:0] DESCRIPTOR_HID [63] = '{ 'h05, 'h01, 'h09, 'h06, 'ha1, 'h01, 'h05, 'h07, 'h19, 'he0, 'h29, 'he7, 'h15, 'h00, 'h25, 'h01, 'h75, 'h01, 'h95, 'h08, 'h81, 'h02, 'h95, 'h01, 'h75, 'h08, 'h81, 'h03, 'h95, 'h05, 'h75, 'h01, 'h05, 'h08, 'h19, 'h01, 'h29, 'h05, 'h91, 'h02, 'h95, 'h01, 'h75, 'h03, 'h91, 'h03, 'h95, 'h06, 'h75, 'h08, 'h15, 'h00, 'h25, 'hff, 'h05, 'h07, 'h19, 'h00, 'h29, 'h65, 'h81, 'h00, 'hc0 };

always @ (posedge clk)
    if(ep00_setup_cmd[15:0] == 16'h0681)
        ep00_resp <= DESCRIPTOR_HID[ep00_resp_idx];
    else
        ep00_resp <= '0;




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top #(
    .DESCRIPTOR_DEVICE  ( '{  //  18 bytes available
        'h12, 'h01, 'h10, 'h01, 'h00, 'h00, 'h00, 'h20, 'h9A, 'hFB, 'h9A, 'hFB, 'h00, 'h01, 'h01, 'h02, 'h00, 'h01
    } ),
    .DESCRIPTOR_STR1    ( '{  //  64 bytes available
        'h2C, 'h03, "g" , 'h00, "i" , 'h00, "t" , 'h00, "h" , 'h00, "u" , 'h00, "b" , 'h00, "." , 'h00, "c" , 'h00, "o" , 'h00, "m" , 'h00, "/" , 'h00, "W" , 'h00, "a" , 'h00, "n" , 'h00, "g" , 'h00, "X" , 'h00, "u" , 'h00, "a" , 'h00, "n" , 'h00, "9" , 'h00, "5" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_STR2    ( '{  //  64 bytes available
        'h24, 'h03, "F" , 'h00, "P" , 'h00, "G" , 'h00, "A" , 'h00, "-" , 'h00, "U" , 'h00, "S" , 'h00, "B" , 'h00, "-" , 'h00, "K" , 'h00, "e" , 'h00, "y" , 'h00, "b" , 'h00, "o" , 'h00, "a" , 'h00, "r" , 'h00, "d" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_CONFIG  ( '{  // 512 bytes available
        'h09, 'h02, 'h22, 'h00, 'h01, 'h01, 'h00, 'h80, 'h64,      // configuration descriptor
        'h09, 'h04, 'h00, 'h00, 'h01, 'h03, 'h01, 'h01, 'h00,      // interface descriptor
        'h09, 'h21, 'h11, 'h01, 'h00, 'h01, 'h22, 'h3f, 'h00,      // HID descriptor
        'h07, 'h05, 'h81, 'h03, 'h08, 'h00, 'h64,                  // endpoint descriptor (IN)
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .EP81_MAXPKTSIZE    ( 10'h08           ),
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
    .ep00_setup_cmd     ( ep00_setup_cmd   ),
    .ep00_resp_idx      ( ep00_resp_idx    ),
    .ep00_resp          ( ep00_resp        ),
    .ep81_data          ( in_data[7:0]     ),
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
