
//--------------------------------------------------------------------------------------------------------
// Module  : usbfs_debug_monitor
// Type    : synthesizable, IP's sub module
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: USB monitor : for printing debug info
//--------------------------------------------------------------------------------------------------------

module usbfs_debug_monitor (
    input  wire        rstn,
    input  wire        clk,
    // RX packet-level signals
    input  wire [ 3:0] rp_pid,
    input  wire [ 3:0] rp_endp,
    input  wire        rp_byte_en,
    input  wire [ 7:0] rp_byte,
    input  wire        rp_fin,
    input  wire        rp_okay,
    // TX packet-level signals
    input  wire [ 3:0] tp_pid,
    input  wire        tp_byte_req,
    input  wire [ 7:0] tp_byte,
    input  wire        tp_fin_n,
    // debug output info
    output reg         debug_en,
    output reg  [ 7:0] debug_data
);


initial {debug_en, debug_data} = '0;


function automatic logic [7:0] hex2ascii (input [3:0] hex);
    return {4'h3, hex} + ((hex<4'hA) ? 8'h0 : 8'h7) ;
endfunction



localparam [3:0] PID_OUT    = 4'h1;
localparam [3:0] PID_IN     = 4'h9;
localparam [3:0] PID_SETUP  = 4'hD;
localparam [3:0] PID_SOF    = 4'h5;
localparam [3:0] PID_DATA0  = 4'h3;
localparam [3:0] PID_DATA1  = 4'hB;
localparam [3:0] PID_DATA2  = 4'h7;  // unused in USB 1.1
//localparam [3:0] PID_MDATA  = 4'hF;  // unused in USB 1.1
localparam [3:0] PID_ACK    = 4'h2;
localparam [3:0] PID_NAK    = 4'hA;
//localparam [3:0] PID_STALL  = 4'hE;  // unused in this USB 1.1 device core
//localparam [3:0] PID_NYET   = 4'h6;  // unused in USB 1.1



reg [ 2:0] cnt = '0;
reg [ 7:0] data [6] = '{6{'0}};



task LoadSendData(input logic [2:0] _cnt, input logic [7:0] _data [6]);
    cnt  <= _cnt;
    data <= _data;
endtask



reg        tp_byte_en = 1'b0;
always @ (posedge clk or negedge rstn)
    if(~rstn)
        tp_byte_en <= 1'b0;
    else
        tp_byte_en <= tp_byte_req;


always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        cnt  <= '0;
        data <= '{6{'0}};
        debug_en   <= 1'b0;
        debug_data <= '0;
    end else begin
        debug_en   <= 1'b0;
        if(cnt > 3'd0) begin
            cnt  <= cnt - 3'd1;
            data <= '{data[1], data[2], data[3], data[4], data[5] , 0 };
            debug_en   <= 1'b1;
            debug_data <= data[0];
        end
        if(rp_byte_en) begin                                                                            // RX a byte
            LoadSendData( 2, '{ hex2ascii(rp_byte[7:4]), hex2ascii(rp_byte[3:0]), 0, 0, 0, 0} );
        end else if(rp_fin &  rp_okay) begin                                                            // RX packet finish (without error)
            case(rp_pid)
                PID_SOF    : begin end // LoadSendData( 2 , '{ "\n", "f", 0, 0, 0, 0 } );                            // print nothing when receiving a SOF token
                PID_OUT    : LoadSendData( 6 , '{ "\n", "-", ">", "0", hex2ascii(rp_endp), " " } );
                PID_IN     : LoadSendData( 6 , '{ "\n", "<", "-", "8", hex2ascii(rp_endp), " " } );
                PID_SETUP  : LoadSendData( 4 , '{ "\n", "s", "u", " ",  0 ,  0  } );
                PID_DATA0  : LoadSendData( 3 , '{  " ", "d", "0",  0 ,  0 ,  0  } );
                PID_DATA1  : LoadSendData( 3 , '{  " ", "d", "1",  0 ,  0 ,  0  } );
                PID_DATA2  : LoadSendData( 3 , '{  " ", "d", "2",  0 ,  0 ,  0  } );
                PID_ACK    : LoadSendData( 4 , '{  " ", "a", "c", "k",  0 ,  0  } );
                PID_NAK    : LoadSendData( 4 , '{  " ", "n", "a", "k",  0 ,  0  } );
                default    : LoadSendData( 6 , '{ "\n", "p", "i", "d", "=", hex2ascii(rp_pid) } );      // normally a USB1.1 host will not send other PIDs, but here we still print it
            endcase
        end else if(rp_fin & ~rp_okay) begin                                                            // RX packet finish (with error)
            if( rp_pid == PID_OUT || rp_pid == PID_IN || rp_pid == PID_SETUP )
                LoadSendData( 6, '{ "\n", "e", "r", "r", "*", "*" } );
            else
                LoadSendData( 6, '{  " ", "e", "r", "r", "*", "*" } );
        end else if(tp_byte_en &  tp_fin_n) begin                                                       // TX a byte
            LoadSendData( 2, '{ hex2ascii(tp_byte[7:4]), hex2ascii(tp_byte[3:0]), 0, 0, 0, 0} );
        end else if(tp_byte_en & ~tp_fin_n) begin                                                       // TX packet finish
            case(tp_pid)
                PID_DATA0  : LoadSendData( 3 , '{  " ", "d", "0",  0 ,  0 ,  0  } );
                PID_DATA1  : LoadSendData( 3 , '{  " ", "d", "1",  0 ,  0 ,  0  } );
                //PID_ACK    : LoadSendData( 4 , '{  " ", "a", "c", "k",  0 ,  0  } );
                //PID_NAK    : LoadSendData( 4 , '{  " ", "n", "a", "k",  0 ,  0  } );
            endcase
        end
    end



endmodule
