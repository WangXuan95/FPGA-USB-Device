
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_transaction
// Type    : synthesizable, IP's sub module
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: USB device transaction level controller
//--------------------------------------------------------------------------------------------------------
// ep00_setup_cmd structure:
// |  wLength  |  wIndex   |  wValue   |  bRequest  |  bmRequestType                      |
// |  wLength  |  wIndex   |  wValue   |  bRequest  |  Direction  |  Type   |  Recipient  |
// |  [63:48]  |  [47:32]  |  [31:16]  |  [15:8]    |  [7]        |  [6:5]  |  [4:0]      |
//--------------------------------------------------------------------------------------------------------

module usbfs_transaction #(
    parameter logic [7:0] DESCRIPTOR_DEVICE [ 18] = '{ 18{'0}},
    parameter logic [7:0] DESCRIPTOR_STR1   [ 64] = '{ 64{'0}},
    parameter logic [7:0] DESCRIPTOR_STR2   [ 64] = '{ 64{'0}},
    parameter logic [7:0] DESCRIPTOR_STR3   [ 64] = '{ 64{'0}},
    parameter logic [7:0] DESCRIPTOR_STR4   [ 64] = '{ 64{'0}},
    parameter logic [7:0] DESCRIPTOR_STR5   [ 64] = '{ 64{'0}},
    parameter logic [7:0] DESCRIPTOR_STR6   [ 64] = '{ 64{'0}},
    parameter logic [7:0] DESCRIPTOR_CONFIG [512] = '{512{'0}},
    parameter logic [7:0] EP00_MAXPKTSIZE  = 8'h20,
    parameter logic [9:0] EP81_MAXPKTSIZE  = 10'h20,
    parameter logic [9:0] EP82_MAXPKTSIZE  = 10'h20,
    parameter logic [9:0] EP83_MAXPKTSIZE  = 10'h20,
    parameter logic [9:0] EP84_MAXPKTSIZE  = 10'h20,
    parameter             EP81_ISOCHRONOUS = 0,
    parameter             EP82_ISOCHRONOUS = 0,
    parameter             EP83_ISOCHRONOUS = 0,
    parameter             EP84_ISOCHRONOUS = 0,
    parameter             EP01_ISOCHRONOUS = 0,
    parameter             EP02_ISOCHRONOUS = 0,
    parameter             EP03_ISOCHRONOUS = 0,
    parameter             EP04_ISOCHRONOUS = 0
) (
    input  wire        rstn,
    input  wire        clk,
    // RX packet-level signals
    input  wire [ 3:0] rp_pid,
    input  wire [ 3:0] rp_endp,
    input  wire        rp_byte_en,
    input  wire [ 7:0] rp_byte,
    input  wire        rp_fin,
    input  wire        rp_okay,
    // TX packet-level signals (device NEVER send token and special packet)
    output reg         tp_sta,
    output reg  [ 3:0] tp_pid,
    input  wire        tp_byte_req,
    output reg  [ 7:0] tp_byte,
    output reg         tp_fin_n,
    // 
    output reg         sot,            // detect a start of USB-transfer
    output reg         sof,            // detect a start of USB-frame
    // endpoint 0 (control endpoint) command response interface
    output reg  [63:0] ep00_setup_cmd,
    output reg  [ 8:0] ep00_resp_idx,
    input  wire [ 7:0] ep00_resp,
    // endpoint 0x81 data input
    input  wire [ 7:0] ep81_data,
    input  wire        ep81_valid,
    output wire        ep81_ready,
    // endpoint 0x82 data input
    input  wire [ 7:0] ep82_data,
    input  wire        ep82_valid,
    output wire        ep82_ready,
    // endpoint 0x83 data input
    input  wire [ 7:0] ep83_data,
    input  wire        ep83_valid,
    output wire        ep83_ready,
    // endpoint 0x84 data input
    input  wire [ 7:0] ep84_data,
    input  wire        ep84_valid,
    output wire        ep84_ready,
    // endpoint 0x01 data output
    output reg  [ 7:0] ep01_data,
    output reg         ep01_valid,
    // endpoint 0x02 data output
    output reg  [ 7:0] ep02_data,
    output reg         ep02_valid,
    // endpoint 0x03 data output
    output reg  [ 7:0] ep03_data,
    output reg         ep03_valid,
    // endpoint 0x04 data output
    output reg  [ 7:0] ep04_data,
    output reg         ep04_valid
);


initial {tp_sta, tp_pid, tp_byte, tp_fin_n} = '0;
initial {sot, sof} = '0;
initial ep00_setup_cmd = '0;
initial ep00_resp_idx = '0;
initial {ep01_data, ep01_valid} = '0;
initial {ep02_data, ep02_valid} = '0;
initial {ep03_data, ep03_valid} = '0;
initial {ep04_data, ep04_valid} = '0;


localparam [3:0] PID_OUT    = 4'h1;
localparam [3:0] PID_IN     = 4'h9;
localparam [3:0] PID_SETUP  = 4'hD;
localparam [3:0] PID_SOF    = 4'h5;
localparam [3:0] PID_DATA0  = 4'h3;
localparam [3:0] PID_DATA1  = 4'hB;
//localparam [3:0] PID_DATA2  = 4'h7;  // unused in USB 1.1
//localparam [3:0] PID_MDATA  = 4'hF;  // unused in USB 1.1
localparam [3:0] PID_ACK    = 4'h2;
localparam [3:0] PID_NAK    = 4'hA;
//localparam [3:0] PID_STALL  = 4'hE;  // unused in this USB 1.1 device core
//localparam [3:0] PID_NYET   = 4'h6;  // unused in USB 1.1


reg [ 9:0] tp_cnt = '0;
reg [ 3:0] endp = '0;
reg        ep00_setup = '0;
reg [15:0] ep00_total = '0;
reg [ 7:0] ep00_data = '0;
reg        ep00_data1 = '0;
reg        ep81_data1 = '0;
reg        ep82_data1 = '0;
reg        ep83_data1 = '0;
reg        ep84_data1 = '0;

wire       ep8x_valid [5] = '{  1'b1    , ep81_valid, ep82_valid, ep83_valid, ep84_valid};
wire [7:0] ep8x_data  [5] = '{ep00_data , ep81_data , ep82_data , ep83_data , ep84_data};



//-------------------------------------------------------------------------------------------------------------------------------------
// main
//-------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        {tp_sta, tp_pid, tp_byte, tp_fin_n} <= '0;
        tp_cnt <= '0;
        endp <= '0;
        {ep00_data1, ep81_data1, ep82_data1, ep83_data1, ep84_data1} <= '0;
        ep00_setup <= '0;
        ep00_total <= '0;
        ep00_resp_idx <= '0;
    end else begin
        tp_sta <= 1'b0;
        if(rp_fin & rp_okay) begin                                                 // recv a packet
            if         (rp_pid == PID_SETUP) begin                                 //   recv SETUP token
                endp <= rp_endp;                                                   //
                ep00_setup <= 1'b1;                                                //
                ep00_data1 <= 1'b1;                                                //
            end else if(rp_pid == PID_OUT) begin                                   //   recv OUT token
                endp <= rp_endp;                                                   //
                ep00_setup <= 1'b0;                                                //
            end else if(rp_pid == PID_IN) begin                                    //   recv IN token
                endp <= rp_endp;                                                   //
                ep00_setup <= 1'b0;                                                //
                tp_sta <= 1'b1;                                                    //
                tp_pid <= PID_NAK;                                                 //     send NAK by default
                tp_cnt <= '0;                                                      //     send len = 0 by default
                if(rp_endp == 4'd0) begin                                          //     if IN ENDP=0
                    tp_pid <= ep00_data1 ? PID_DATA1 : PID_DATA0;                  //       send DATA1 or DATA0
                    ep00_data1 <= ~ep00_data1;                                     //       DATA0/1 flop
                    if(ep00_total >= {8'h0,EP00_MAXPKTSIZE}) begin                 //
                        tp_cnt <= {2'h0, EP00_MAXPKTSIZE};                         //
                        ep00_total <= ep00_total - {8'h0,EP00_MAXPKTSIZE};         //
                    end else begin                                                 //
                        tp_cnt <= {2'h0, ep00_total[7:0]};                         //
                        ep00_total <= '0;                                          //
                    end                                                            //
                end else if(rp_endp == 4'd1) begin                                 //     if IN ENDP=1
                    if(ep81_valid) begin                                           //
                        tp_pid <= (ep81_data1 && !EP81_ISOCHRONOUS) ? PID_DATA1 : PID_DATA0;
                        ep81_data1 <= ~ep81_data1;                                 //       DATA0/1 flop
                        tp_cnt <= EP81_MAXPKTSIZE;                                 //
                    end                                                            //
                end else if(rp_endp == 4'd2) begin                                 //     if IN ENDP=2
                    if(ep82_valid) begin                                           //
                        tp_pid <= (ep82_data1 && !EP82_ISOCHRONOUS) ? PID_DATA1 : PID_DATA0;
                        ep82_data1 <= ~ep82_data1;                                 //       DATA0/1 flop
                        tp_cnt <= EP82_MAXPKTSIZE;                                 //
                    end                                                            //
                end else if(rp_endp == 4'd3) begin                                 //     if IN ENDP=3
                    if(ep83_valid) begin                                           //
                        tp_pid <= (ep83_data1 && !EP83_ISOCHRONOUS) ? PID_DATA1 : PID_DATA0;
                        ep83_data1 <= ~ep83_data1;                                 //       DATA0/1 flop
                        tp_cnt <= EP83_MAXPKTSIZE;                                 //
                    end                                                            //
                end else if(rp_endp == 4'd4) begin                                 //     if IN ENDP=4
                    if(ep84_valid) begin                                           //
                        tp_pid <= (ep84_data1 && !EP84_ISOCHRONOUS) ? PID_DATA1 : PID_DATA0;
                        ep84_data1 <= ~ep84_data1;                                 //       DATA0/1 flop
                        tp_cnt <= EP84_MAXPKTSIZE;                                 //
                    end                                                            //
                end                                                                //
            end else if(rp_pid == PID_DATA0 || rp_pid == PID_DATA1) begin          //   recv packet is DATA0 or DATA1
                ep00_total <= '0;                                                  //
                if(endp == 4'd0 && ep00_setup) begin                               //     if last token = SETUP, device has received a SETUP command
                    if(ep00_setup_cmd[7])                                          //
                        ep00_total <= ep00_setup_cmd[63:48];                       //
                    ep00_resp_idx <= '0;                                           //
                end                                                                //
                tp_pid <= PID_ACK;                                                 //
                if( (endp == 4'd1 && EP01_ISOCHRONOUS) ||                          //
                    (endp == 4'd2 && EP02_ISOCHRONOUS) ||                          //
                    (endp == 4'd3 && EP03_ISOCHRONOUS) ||                          //
                    (endp == 4'd4 && EP04_ISOCHRONOUS)   )                         //     if this recv data packet corresponds to a ISOCHRONOUS OUT endpoint.
                    tp_sta <= 1'b0;                                                //       do not send ACK.
                else                                                               //     otherwise,
                    tp_sta <= 1'b1;                                                //       send ACK
            end                                                                    //
        end                                                                        //
        if(tp_byte_req) begin
            tp_fin_n <= 1'b0;
            if( tp_cnt != '0 && ep8x_valid[endp] ) begin
                tp_cnt <= tp_cnt - 10'd1;
                tp_fin_n <= 1'b1;
                tp_byte <= ep8x_data[endp];
                ep00_resp_idx <= ep00_resp_idx + 9'd1;
            end
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// when tp_byte_req=1 , endpoint number matching, and there is data to send, then the IN endpoint is ready to send a data
//-------------------------------------------------------------------------------------------------------------------------------------
assign ep81_ready = (tp_byte_req && tp_cnt != '0 && endp == 4'd1);
assign ep82_ready = (tp_byte_req && tp_cnt != '0 && endp == 4'd2);
assign ep83_ready = (tp_byte_req && tp_cnt != '0 && endp == 4'd3);
assign ep84_ready = (tp_byte_req && tp_cnt != '0 && endp == 4'd4);



//-------------------------------------------------------------------------------------------------------------------------------------
// response IN data on endpoint 0 (control endpoint)
//-------------------------------------------------------------------------------------------------------------------------------------
localparam logic [7:0] DESCRIPTOR_STR0 [4] = '{'h04, 'h03, 'h09, 'h04};
always @ (posedge clk)
    casex(ep00_setup_cmd[31:0])
        32'h_XXXX_08_80  : ep00_data <= (ep00_resp_idx>=  9'd1) ? 8'h00 : 8'h01;                             // GetConfiguration -> response configuration 1
        32'h_01XX_06_80  : ep00_data <= (ep00_resp_idx>= 9'd18) ? 8'h00 : DESCRIPTOR_DEVICE[ep00_resp_idx];  // GetDescriptor -> response device descriptor
        32'h_02XX_06_80  : ep00_data <=                                   DESCRIPTOR_CONFIG[ep00_resp_idx];  // GetDescriptor -> response configuration descriptor
        32'h_0300_06_80  : ep00_data <= (ep00_resp_idx>=  9'd4) ? 8'h00 : DESCRIPTOR_STR0  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 0
        32'h_0301_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR1  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 1
        32'h_0302_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR2  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 2
        32'h_0303_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR3  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 3
        32'h_0304_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR4  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 4
        32'h_0305_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR5  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 5
        32'h_0306_06_80  : ep00_data <= (ep00_resp_idx>= 9'd64) ? 8'h00 : DESCRIPTOR_STR6  [ep00_resp_idx];  // GetDescriptor -> response string descriptor 6
        default          : ep00_data <= ep00_resp;                                                           // other : response by user
    endcase



//-------------------------------------------------------------------------------------------------------------------------------------
// process OUT data
//-------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        ep00_setup_cmd <= '0;
        {ep01_data, ep01_valid} <= '0;
        {ep02_data, ep02_valid} <= '0;
        {ep03_data, ep03_valid} <= '0;
        {ep04_data, ep04_valid} <= '0;
    end else begin
        {ep01_valid, ep02_valid, ep03_valid, ep04_valid} <= '0;
        if(rp_byte_en) begin
            if(endp == 4'd0) begin               // endpoint 0 OUT -> SETUP command
                if(ep00_setup)
                    ep00_setup_cmd <= {rp_byte, ep00_setup_cmd[63:8]};    // save 8 bytes SETUP command
            end else if(endp == 4'd1) begin      // endpoint 01 OUT
                ep01_data  <= rp_byte;
                ep01_valid <= 1'b1;
            end else if(endp == 4'd2) begin      // endpoint 02 OUT
                ep02_data  <= rp_byte;
                ep02_valid <= 1'b1;
            end else if(endp == 4'd3) begin      // endpoint 03 OUT
                ep03_data  <= rp_byte;
                ep03_valid <= 1'b1;
            end else if(endp == 4'd4) begin      // endpoint 04 OUT
                ep04_data  <= rp_byte;
                ep04_valid <= 1'b1;
            end
        end
    end



//-------------------------------------------------------------------------------------------------------------------------------------
// detect the IN/OUT packet border and the SOF
//-------------------------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        sot <= 1'b0;
        sof <= 1'b0;
    end else begin
        sot <= 1'b0;
        sof <= 1'b0;
        if(rp_fin & rp_okay) begin
            if(rp_endp == 4'd0) begin
                sot <= (rp_pid == PID_SETUP);
            end else begin
                sot <= (rp_pid == PID_IN || rp_pid == PID_OUT);
            end
            sof <= (rp_pid == PID_SOF);
        end
    end



endmodule
