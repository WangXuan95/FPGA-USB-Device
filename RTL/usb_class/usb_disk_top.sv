
//--------------------------------------------------------------------------------------------------------
// Module  : usb_disk_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
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


initial {mem_addr, mem_wen, mem_wdata} = '0;



//-------------------------------------------------------------------------------------------------------------------------------------
// USB bulk-only SCSI transparent command set controller
//-------------------------------------------------------------------------------------------------------------------------------------

localparam [31:0] LAST_BLOCK_INDEX = BLOCK_COUNT - 1;
localparam [15:0] BLOCK_SIZE       = 16'h0200;

enum logic [2:0] {OUT_CBW, IN_RESP, IN_MEM, OUT_MEM, PRE_CSW, IN_CSW} status = OUT_CBW;

reg [31:0] cnt = 0;
reg [40:0] addr = '0;

struct packed {
    // CBWCB
    logic [ 7:0] LEN0, LEN1;
    logic [ 7:0] rsvd2;
    logic [ 7:0] LBA0, LBA1, LBA2, LBA3;
    logic [ 7:0] rsvd1;
    logic [ 7:0] opcode;
    // CBW header
    logic [ 7:0] bCBWCBLength;
    logic [ 7:0] bCBWLUN;
    logic        bmCBWFlags_direction;
    logic [ 6:0] bmCBWFlags_resv;
    logic [31:0] dCBWDataTransferLength;
    logic [31:0] dCBWTag;
    logic [31:0] dCBWSignature;
} CBW = '0;

wire [31:0] LBA = { CBW.LBA3, CBW.LBA2, CBW.LBA1, CBW.LBA0 };
wire [15:0] LEN = {                     CBW.LEN1, CBW.LEN0 };

//wire [36*8-1:0] resp_INQUIRY   = 288'h20312E30_2020202020696E694D2072657A757243_206B7369446E6153_000000_1F_01_00_80_00;
wire [ 8*8-1:0] resp_INQUIRY   = 64'h000000_1F_01_00_80_00;
wire [ 8*8-1:0] resp_CAPACITY  =  {BLOCK_SIZE[7:0], BLOCK_SIZE[15:8], 16'h0000, LAST_BLOCK_INDEX[7:0], LAST_BLOCK_INDEX[15:8], LAST_BLOCK_INDEX[23:16], LAST_BLOCK_INDEX[31:24]};
wire [12*8-1:0] resp_FORMAT    =  {BLOCK_SIZE[7:0], BLOCK_SIZE[15:8], 16'h0001, LAST_BLOCK_INDEX[7:0], LAST_BLOCK_INDEX[15:8], LAST_BLOCK_INDEX[23:16], LAST_BLOCK_INDEX[31:24], 32'h08000000};
wire [ 8*8-1:0] resp_MODESENSE =  32'h00000003;
wire [14*8-1:0] resp_REQSENSE  = 112'h24_00000000_0A_00000000_05_00_70;
wire [13*8-1:0] resp_CSW       = {8'h0, 32'h0, CBW.dCBWTag, 32'h53425355};

reg  [14*8-1:0] resp_shift = '0;

wire            sot;

wire [     7:0] out_data;
wire            out_valid;
wire            in_valid = ((status == IN_RESP) || (status == IN_MEM) || (status == IN_CSW)) && (cnt > 0);
wire [     7:0] in_data  =  (status == IN_MEM) ? mem_rdata : resp_shift[7:0];
wire            in_ready;

always @ (posedge clk) begin
    mem_addr  <= addr;
    mem_wen   <= (status == OUT_MEM) && (cnt > 0) && out_valid;
    mem_wdata <= out_data;
end

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        CBW <= '0;
        resp_shift <= '0;
        cnt <= 0;
        addr <= '0;
        status <= OUT_CBW;
    end else begin
        case(status)
            
            OUT_CBW  : if(cnt < 24) begin
                if(out_valid) begin
                    CBW <= {out_data, CBW[191:8]};
                    cnt <= cnt + 1;
                end
            end else if(sot) begin
                status <= IN_RESP;
                if         (CBW.opcode == 8'h12) begin                           // INQUIRY
                    resp_shift <= resp_INQUIRY;
                    cnt <= 36;
                end else if(CBW.opcode == 8'h25) begin                           // READ CAPACITY
                    resp_shift <= resp_CAPACITY;
                    cnt <= 8;
                end else if(CBW.opcode == 8'h23) begin                           // READ FORMAT CAPACITY
                    resp_shift <= resp_FORMAT;
                    cnt <= 12;
                end else if(CBW.opcode == 8'h1A || CBW.opcode == 8'h5A) begin    // MODE SENSE
                    resp_shift <= resp_MODESENSE;
                    cnt <= 4;
                end else if(CBW.opcode == 8'h03) begin                           // REQUEST SENSE
                    resp_shift <= resp_REQSENSE;
                    cnt <= 18;
                end else if(CBW.opcode == 8'h28 || CBW.opcode == 8'h2A) begin    // READ(10) or WRITE(10)
                    addr <= {LBA, 9'h0};
                    cnt <= {7'h0, LEN , 9'h0};
                    status <= CBW.opcode == 8'h28 ? IN_MEM : OUT_MEM;
                end else begin
                    status <= PRE_CSW;
                end
            end
            
            IN_RESP   : if(cnt > 0) begin
                if(in_ready) begin
                    resp_shift <= resp_shift >> 8;
                    cnt <= cnt - 1;
                end
            end else if(sot) begin
                status <= PRE_CSW;
            end
            
            IN_MEM   : if(cnt > 0) begin
                if(in_ready) begin
                    addr <= addr + 41'd1;
                    cnt <= cnt - 1;
                end
            end else if(sot) begin
                status <= PRE_CSW;
            end
            
            OUT_MEM  : if(cnt > 0) begin
                if(out_valid) begin
                    addr <= addr + 41'd1;
                    cnt <= cnt - 1;
                end
            end else if(sot) begin
                status <= PRE_CSW;
            end
            
            PRE_CSW  : begin
                resp_shift <= resp_CSW;
                cnt <= 13;
                status <= IN_CSW;
            end
            
            IN_CSW   : if(cnt > 0) begin
                if(in_ready) begin
                    resp_shift <= resp_shift >> 8;
                    cnt <= cnt - 1;
                end
            end else if(sot) begin
                status <= OUT_CBW;
            end
            
        endcase
    end




//-------------------------------------------------------------------------------------------------------------------------------------
// USB full-speed core
//-------------------------------------------------------------------------------------------------------------------------------------
usbfs_core_top  #(
    .DESCRIPTOR_DEVICE  ( '{  //  18 bytes available
        'h12, 'h01, 'h10, 'h01, 'h00, 'h00, 'h00, 'h20, 'h9A, 'hFB, 'h9A, 'hFB, 'h00, 'h01, 'h01, 'h02, 'h00, 'h01
    } ),
    .DESCRIPTOR_STR1    ( '{  //  64 bytes available
        'h2C, 'h03, "g" , 'h00, "i" , 'h00, "t" , 'h00, "h" , 'h00, "u" , 'h00, "b" , 'h00, "." , 'h00, "c" , 'h00, "o" , 'h00, "m" , 'h00, "/" , 'h00, "W" , 'h00, "a" , 'h00, "n" , 'h00, "g" , 'h00, "X" , 'h00, "u" , 'h00, "a" , 'h00, "n" , 'h00, "9" , 'h00, "5" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_STR2    ( '{  //  64 bytes available
        'h1C, 'h03, "F" , 'h00, "P" , 'h00, "G" , 'h00, "A" , 'h00, "-" , 'h00, "U" , 'h00, "S" , 'h00, "B" , 'h00, "-" , 'h00, "d" , 'h00, "i" , 'h00, "s" , 'h00, "k" , 'h00,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    } ),
    .DESCRIPTOR_CONFIG  ( '{  // 512 bytes available
        'h09, 'h02, 'h20, 'h00, 'h01, 'h01, 'h00, 'h80, 'h64,    // configuration descriptor
        'h09, 'h04, 'h00, 'h00, 'h02, 'h08, 'h06, 'h50, 'h00,    // interface descriptor (mass storage class)
        'h07, 'h05, 'h01, 'h02, 'h40, 'h00, 'h00,                // endpoint descriptor (bulk OUT)
        'h07, 'h05, 'h82, 'h02, 'h40, 'h00, 'h00,                // endpoint descriptor (bulk IN)
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
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
