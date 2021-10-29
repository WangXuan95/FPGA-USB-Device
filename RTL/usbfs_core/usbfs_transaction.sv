`timescale 1ns/1ns

// module usbfs_transaction
//    USB device transaction level controller
module usbfs_transaction #(
    parameter [9:0] ENDP_00_MAXPKTSIZE = 10'd32,
    parameter [9:0] ENDP_81_MAXPKTSIZE = 10'd32
) (
    input  wire        rstn,
    input  wire        clk,
    // RX packet-level signals
    input  wire [ 3:0] rp_pid,
    input  wire [10:0] rp_addr,
    input  wire        rp_byte_en,
    input  wire [ 7:0] rp_byte,
    input  wire        rp_fin,
    input  wire        rp_okay,
    // TX packet-level interface (device NEVER send token and special packet)
    output reg         tp_sta,
    output reg  [ 3:0] tp_pid,
    input  wire        tp_byte_req,
    output reg  [ 7:0] tp_byte,
    output reg         tp_fin_n,
    // descriptor ROM read interface
    output reg  [ 9:0] desc_addr,
    input  wire [ 7:0] desc_data,
    // endpoint 0x01 data output
    output reg  [ 7:0] out_data,
    output reg         out_valid,
    // endpoint 0x81 data input
    input  wire [ 7:0] in_data,
    input  wire        in_valid,
    output wire        in_ready
);

initial {tp_sta, tp_pid, tp_byte, tp_fin_n} = '0;
initial desc_addr = '1;
initial {out_data, out_valid} = '0;

wire[ 3:0] rp_endp = rp_addr[10:7];
reg        issetup = '0;
reg [ 3:0] endp = '0;

reg        endp_00_data1 = '0;
reg [ 9:0] endp_00_count = '0;
reg [15:0] endp_00_total = '0;
reg        endp_00_response_desc = '0;
reg [15:0] endp_00_response_reg = '0;

reg        endp_81_data1 = '0;
reg [ 9:0] endp_81_count = '0;

struct packed {
    logic [15:0] wLength;
    logic [15:0] wIndex;
    logic [15:0] wValue;
    logic [ 7:0] bRequest;
    logic        bitRequestDirection;
    logic [ 6:0] bRequestType;
} setup_cmd;


always @ (posedge clk)
    if(~rstn) begin
        {tp_sta, tp_pid, tp_byte, tp_fin_n} <= '0;
        desc_addr <= '1;
        {issetup, endp} <= '0;
        {endp_00_data1, endp_00_count, endp_00_total, endp_00_response_desc, endp_00_response_reg} <= '0;
        {endp_81_data1, endp_81_count} <= '0;
    end else begin
        tp_sta <= 1'b0;
        if(rp_fin & rp_okay) begin                                                                        // end of a recv packet
            if(rp_pid == 4'hD || rp_pid == 4'h1 || rp_pid == 4'h9) begin                                  //   end of a SETUP, IN or OUT token packet
                issetup <= rp_pid == 4'hD;
                endp <= rp_endp;
                if(rp_pid == 4'h9) begin                                                                  //     token=IN
                    tp_sta <= 1'b1;                                                                       //
                    tp_pid <= 4'hA;                                                                       //       send NAK by default
                    endp_00_count <= '0;                                                                  //       send len = 0 by default
                    if(rp_endp == 4'd0) begin                                                             //       if ENDP=0
                        tp_pid <= endp_00_data1 ? 4'hB : 4'h3;                                            //         send DATA1 or DATA0
                        endp_00_data1 <= ~endp_00_data1;                                                  //
                        if(endp_00_total >= {6'h0,ENDP_00_MAXPKTSIZE}) begin
                            endp_00_count <= ENDP_00_MAXPKTSIZE;
                            endp_00_total <= endp_00_total - {6'h0,ENDP_00_MAXPKTSIZE};
                        end else begin
                            endp_00_count <= (10)'(endp_00_total);
                            endp_00_total <= '0;
                        end
                    end else if(rp_endp == 4'd1) begin
                        if(in_valid) begin
                            tp_pid <= endp_81_data1 ? 4'hB : 4'h3;
                            endp_81_data1 <= ~endp_81_data1;
                            endp_81_count <= ENDP_81_MAXPKTSIZE;
                        end
                    end
                end
            end else if(rp_pid == 4'h3 || rp_pid == 4'hB) begin                                           //   end of a DATA0 or DATA1 packet
                tp_sta <= 1'b1;                                                                           //     
                tp_pid <= 4'h2;                                                                           //     send ACK
                {endp_00_data1, endp_00_total} <= '0;                                                     //
                if(endp == 4'd0 && issetup) begin                                                         //     if last token = SETUP, device has received a SETUP command
                    endp_00_data1 <= 1'b1;                                                                //
                    endp_00_total <= setup_cmd.bitRequestDirection ? setup_cmd.wLength : '0;              //
                    endp_00_response_desc <= 1'b0;                                                        //     
                    endp_00_response_reg <= '0;                                                           //
                    case(setup_cmd.bRequest)                                                              //     what's the bRequest
                        8'd6  : endp_00_response_desc <= 1'b1;                                            //       GetDescriptor
                        8'd8  : endp_00_response_reg <= 16'h0001;                                         //       GetConfiguration
                        8'd0  : if(setup_cmd.bRequestType == 7'h00) endp_00_response_reg <= 16'h0003;     //       GetStatus
                    endcase
                    if (setup_cmd.bRequestType == 7'h00) begin                                            //      
                        case(setup_cmd.wValue[15:8])                                                      //         what's the requested descriptor type ?
                            8'h1   :                                        desc_addr <= 10'h000;         //           is device
                            8'h2   :                                        desc_addr <= 10'h100;         //           is configuration
                            8'h3   :      if(setup_cmd.wValue[7:0] == 8'd0) desc_addr <= 10'h020;         //           is string 0
                                     else if(setup_cmd.wValue[7:0] == 8'd1) desc_addr <= 10'h040;         //           is string 1 (manufacturer)
                                     else if(setup_cmd.wValue[7:0] == 8'd2) desc_addr <= 10'h080;         //           is string 2 (product)
                                     else if(setup_cmd.wValue[7:0] == 8'd3) desc_addr <= 10'h0C0;         //           is string 3 (serial-number)
                                     else                                   desc_addr <= '1;              //           unknown
                            default:                                        desc_addr <= '1;              //           unknown
                        endcase                                                                           //
                    end else begin                                                                        //           is HID descriptor
                        desc_addr <= 10'h300;                                                             //
                    end
                end
            end
        end
        if(tp_byte_req) begin
            tp_fin_n <= 1'b0;
            if(endp == 4'd0) begin
                if(endp_00_count != '0) begin
                    endp_00_count <= endp_00_count - 10'd1;
                    endp_00_response_reg <= {8'h00, endp_00_response_reg[15:8]};
                    if(desc_addr != '1)
                        desc_addr <= desc_addr + 10'd1;
                    tp_fin_n <= 1'b1;
                    tp_byte <= endp_00_response_desc ? desc_data : endp_00_response_reg[7:0];
                end
            end else if(endp == 4'd1) begin
                if(endp_81_count != '0 && in_valid) begin
                    endp_81_count <= endp_81_count - 10'd1;
                    tp_fin_n <= 1'b1;
                    tp_byte <= in_data;
                end
            end
        end
    end


assign in_ready = (tp_byte_req && endp == 4'd1 && endp_81_count != '0);


// OUT data
always @ (posedge clk) begin
    {out_data, out_valid} <= '0;
    if(rp_byte_en) begin
        if(endp == 4'd0) begin
            if(issetup)
                setup_cmd <= {rp_byte, setup_cmd[63:8]};
        end else if(endp == 4'd1) begin
            out_data <= rp_byte;
            out_valid <= 1'b1;
        end
    end
end

endmodule
