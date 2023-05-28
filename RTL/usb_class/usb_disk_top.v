
//--------------------------------------------------------------------------------------------------------
// Module  : usb_disk_top
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A USB Full Speed (12Mbps) device, act as a USB disk.
//--------------------------------------------------------------------------------------------------------

module usb_disk_top #(
    parameter BLOCK_COUNT = 65536,    // block count of the disk, each block has 512 bytes
    parameter DEBUG       = "FALSE"   // whether to output USB debug info, "TRUE" or "FALSE"
) (
    input  wire        rstn,          // active-low reset, reset when rstn=0 (USB will unplug when reset), normally set to 1
    input  wire        clk,           // 60MHz is required
    // USB signals
    output wire        usb_dp_pull,   // connect to USB D+ by an 1.5k resistor
    inout              usb_dp,        // USB D+
    inout              usb_dn,        // USB D-
    // USB reset output
    output wire        usb_rstn,      // 1: connected , 0: disconnected (when USB cable unplug, or when system reset (rstn=0))
    // disk memory access interface
    output reg  [40:0] mem_addr,      // byte address
    output reg         mem_wen,       // 1:write   0:read
    output reg  [ 7:0] mem_wdata,     // byte to write
    input  wire [ 7:0] mem_rdata,     // byte to read
    // debug output info, only for USB developers, can be ignored for normally use. Please set DEBUG="TRUE" to enable these signals
    output wire        debug_en,      // when debug_en=1 pulses, a byte of debug info appears on debug_data
    output wire [ 7:0] debug_data,    // 
    output wire        debug_uart_tx  // debug_uart_tx is the signal after converting {debug_en,debug_data} to UART (format: 115200,8,n,1). If you want to transmit debug info via UART, you can use this signal. If you want to transmit debug info via other custom protocols, please ignore this signal and use {debug_en,debug_data}.
);



initial mem_addr  = 41'h0;
initial mem_wen   = 1'b0;
initial mem_wdata = 8'h0;



//-------------------------------------------------------------------------------------------------------------------------------------
// USB bulk-only SCSI transparent command set controller
//-------------------------------------------------------------------------------------------------------------------------------------

localparam [31:0] LAST_BLOCK_INDEX = BLOCK_COUNT - 1;
localparam [15:0] BLOCK_SIZE       = 16'h0200;

localparam [2:0] S_OUT_CBW = 3'd0,
                 S_IN_RESP = 3'd1,
                 S_IN_MEM  = 3'd2,
                 S_OUT_MEM = 3'd3,
                 S_PRE_CSW = 3'd4,
                 S_IN_CSW  = 3'd5;

reg [ 2:0] state = S_OUT_CBW;

reg [31:0] cnt = 0;
reg [40:0] addr = 41'h0;

//struct packed {
// CBWCB ------------------
reg [ 7:0] LEN0, LEN1;
reg [ 7:0] rsvd2;
reg [ 7:0] LBA0, LBA1, LBA2, LBA3;
reg [ 7:0] rsvd1;
reg [ 7:0] opcode;
// CBW header -------------
reg [ 7:0] bCBWCBLength;
reg [ 7:0] bCBWLUN;
reg        bmCBWFlags_direction;
reg [ 6:0] bmCBWFlags_resv;
reg [31:0] dCBWDataTransferLength;
reg [31:0] dCBWTag;
reg [31:0] dCBWSignature;
//} CBW;   // 192 bits in total : {LEN0, LEN1, rsvd2, LBA0, LBA1, LBA2, LBA3, rsvd1, opcode, bCBWCBLength, bCBWLUN, bmCBWFlags_direction, bmCBWFlags_resv, dCBWDataTransferLength, dCBWTag, dCBWSignature}

wire [31:0] LBA = { LBA3, LBA2, LBA1, LBA0 };
wire [15:0] LEN = {             LEN1, LEN0 };

//wire [36*8-1:0] resp_INQUIRY   = 288'h20312E30_2020202020696E694D2072657A757243_206B7369446E6153_000000_1F_01_00_80_00;
wire [ 8*8-1:0] resp_INQUIRY   = 64'h000000_1F_01_00_80_00;
wire [ 8*8-1:0] resp_CAPACITY  =  {BLOCK_SIZE[7:0], BLOCK_SIZE[15:8], 16'h0000, LAST_BLOCK_INDEX[7:0], LAST_BLOCK_INDEX[15:8], LAST_BLOCK_INDEX[23:16], LAST_BLOCK_INDEX[31:24]};
wire [12*8-1:0] resp_FORMAT    =  {BLOCK_SIZE[7:0], BLOCK_SIZE[15:8], 16'h0001, LAST_BLOCK_INDEX[7:0], LAST_BLOCK_INDEX[15:8], LAST_BLOCK_INDEX[23:16], LAST_BLOCK_INDEX[31:24], 32'h08000000};
wire [ 8*8-1:0] resp_MODESENSE =  32'h00000003;
wire [14*8-1:0] resp_REQSENSE  = 112'h24_00000000_0A_00000000_05_00_70;
wire [13*8-1:0] resp_CSW       = {8'h0, 32'h0, dCBWTag, 32'h53425355};

reg  [14*8-1:0] resp_shift = 112'h0;

wire            sot;

wire [     7:0] out_data;
wire            out_valid;
wire            in_valid = ((state == S_IN_RESP) || (state == S_IN_MEM) || (state == S_IN_CSW)) && (cnt > 0);
wire [     7:0] in_data  =  (state == S_IN_MEM) ? mem_rdata : resp_shift[7:0];
wire            in_ready;

always @ (posedge clk) begin
    mem_addr  <= addr;
    mem_wen   <= (state == S_OUT_MEM) && (cnt > 0) && out_valid;
    mem_wdata <= out_data;
end

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        {LEN0, LEN1, rsvd2, LBA0, LBA1, LBA2, LBA3, rsvd1, opcode, bCBWCBLength, bCBWLUN, bmCBWFlags_direction, bmCBWFlags_resv, dCBWDataTransferLength, dCBWTag, dCBWSignature} <= 192'h0;
        resp_shift <= 112'h0;
        cnt <= 0;
        addr <= 41'h0;
        state <= S_OUT_CBW;
    end else begin
        case(state)
            
            S_OUT_CBW  :
                if (cnt < 24) begin
                    if (out_valid) begin
                        {LEN0, LEN1, rsvd2, LBA0, LBA1, LBA2, LBA3, rsvd1, opcode, bCBWCBLength, bCBWLUN, bmCBWFlags_direction, bmCBWFlags_resv, dCBWDataTransferLength, dCBWTag, dCBWSignature} <= {out_data, LEN0, LEN1, rsvd2, LBA0, LBA1, LBA2, LBA3, rsvd1, opcode, bCBWCBLength, bCBWLUN, bmCBWFlags_direction, bmCBWFlags_resv, dCBWDataTransferLength, dCBWTag, dCBWSignature[31:8]};
                        cnt <= cnt + 1;
                    end
                end else if (sot) begin
                    state <= S_IN_RESP;
                    if          (opcode == 8'h12) begin                       // INQUIRY
                        resp_shift <= resp_INQUIRY;
                        cnt <= 36;
                    end else if (opcode == 8'h25) begin                       // READ CAPACITY
                        resp_shift <= resp_CAPACITY;
                        cnt <= 8;
                    end else if (opcode == 8'h23) begin                       // READ FORMAT CAPACITY
                        resp_shift <= resp_FORMAT;
                        cnt <= 12;
                    end else if (opcode == 8'h1A || opcode == 8'h5A) begin    // MODE SENSE
                        resp_shift <= resp_MODESENSE;
                        cnt <= 4;
                    end else if (opcode == 8'h03) begin                       // REQUEST SENSE
                        resp_shift <= resp_REQSENSE;
                        cnt <= 18;
                    end else if (opcode == 8'h28 || opcode == 8'h2A) begin    // READ(10) or WRITE(10)
                        addr <= {LBA, 9'h0};
                        cnt <= {7'h0, LEN , 9'h0};
                        state <= opcode == 8'h28 ? S_IN_MEM : S_OUT_MEM;
                    end else begin
                        state <= S_PRE_CSW;
                    end
                end
            
            S_IN_RESP   :
                if (cnt > 0) begin
                    if (in_ready) begin
                        resp_shift <= (resp_shift >> 8);
                        cnt <= cnt - 1;
                    end
                end else if (sot) begin
                    state <= S_PRE_CSW;
                end
            
            S_IN_MEM   :
                if (cnt > 0) begin
                    if (in_ready) begin
                        addr <= addr + 41'd1;
                        cnt <= cnt - 1;
                    end
                end else if (sot) begin
                    state <= S_PRE_CSW;
                end
            
            S_OUT_MEM  :
                if (cnt > 0) begin
                    if (out_valid) begin
                        addr <= addr + 41'd1;
                        cnt <= cnt - 1;
                    end
                end else if (sot) begin
                    state <= S_PRE_CSW;
                end
            
            S_PRE_CSW  : begin
                resp_shift <= resp_CSW;
                cnt <= 13;
                state <= S_IN_CSW;
            end
            
            default  : //S_IN_CSW   :
                if (cnt > 0) begin
                    if (in_ready) begin
                        resp_shift <= resp_shift >> 8;
                        cnt <= cnt - 1;
                    end
                end else if (sot) begin
                    state <= S_OUT_CBW;
                end
        endcase
    end




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
        224'h1C_03_46_00_50_00_47_00_41_00_2d_00_55_00_53_00_42_00_2d_00_64_00_69_00_73_00_6b_00,                                                  // "FPGA-USB-disk"
        288'h0
    } ),
    .DESCRIPTOR_CONFIG  ( {  // 512 bytes available
        72'h09_02_20_00_01_01_00_80_64,        // configuration descriptor
        72'h09_04_00_00_02_08_06_50_00,        // interface descriptor (mass storage class)
        56'h07_05_01_02_40_00_00,              // endpoint descriptor (bulk OUT)
        56'h07_05_82_02_40_00_00,              // endpoint descriptor (bulk IN)
        3840'h0
    } ),
    .EP82_MAXPKTSIZE    ( 10'h40           ),
    .DEBUG              ( DEBUG            )
) usbfs_core_i (
    .rstn               ( rstn             ),
    .clk                ( clk              ),
    .usb_dp_pull        ( usb_dp_pull      ),
    .usb_dp             ( usb_dp           ),
    .usb_dn             ( usb_dn           ),
    .usb_rstn           ( usb_rstn         ),
    .sot                ( sot              ),
    .sof                (                  ),
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
