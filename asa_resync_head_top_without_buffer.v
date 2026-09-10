timescale 1ns / 1ps

module asa_resync_header_top (
    input  wire          clk,           // System clock
    input  wire          rst_n,         // Active-low synchronous reset
    input  wire          startup_init,  // Synchronous init for PRBS9 Dither source
    input  wire          req,           // Request pulse to generate a new header
    input  wire [2:0]    sg,            // Speed Grade (3'd1 to 3'd5)
    input  wire [15:0]   m_ptb,         // PTB message vector (16 bits)
    
    output reg           ready,         // High when module is idle and ready for 'req'
    output reg           valid,         // High when serial output header is valid
    output reg           tx_phy_rsync_hdr, // 1-bit serial assembled header
    output reg           header_done,      // 1-cycle pulse when complete header is transmitted
    output reg  [10:0]   resylen        // Valid length of the header based on SG
);

    // -------------------------------------------------------------------------
    // FSM States
    // -------------------------------------------------------------------------
    localparam ST_IDLE     = 2'b00;
    localparam ST_GEN_PRBS = 2'b01;
    localparam ST_STREAM   = 2'b10;

    reg [1:0]  state;
    reg [10:0] bit_cnt;
    reg [10:0] tx_cnt;

    // -------------------------------------------------------------------------
    // Internal Signals & Rotator Registers
    // -------------------------------------------------------------------------
    wire          prbs11_en;
    wire          prbs11_bit;
    wire          prbs_stream_out; // Data coming from the new PRBS buffer submodule
    
    reg           prbs9_en;
    wire [4:0]    internal_offset;

    wire [0:39]   sy_fwd;
    wire [0:79]   sy_double_fwd;
    
    wire [39:0]   sy_rev;
    wire [79:0]   sy_double_rev;

    // Rotators for Lint-Safe Streaming
    reg  [79:0]   sy_double_shift;
    reg  [39:0]   sy_shift;
    reg  [15:0]   ptb_shift;

    wire [10:0]   n;
    reg  [10:0]   m;

    // -------------------------------------------------------------------------
    // Static Index Mapping (constant sync seq.)
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 40; i = i + 1) begin : gen_sy_map
            assign sy_rev[i] = sy_fwd[i];
        end
        for (i = 0; i < 80; i = i + 1) begin : gen_syd_map
            assign sy_double_rev[i] = sy_double_fwd[i];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Combinational Logic
    // -------------------------------------------------------------------------
    assign n = 11'd64 + ({6'd0, internal_offset} << 1);

    always @(*) begin
        case (sg)
            3'd1:    m = 11'd264  + {6'd0, internal_offset};
            3'd2:    m = 11'd648  + {6'd0, internal_offset};
            3'd3:    m = 11'd1376 + {6'd0, internal_offset};
            3'd4:    m = 11'd992  + {6'd0, internal_offset};
            3'd5:    m = 11'd1376 + {6'd0, internal_offset};
            default: m = 11'd264  + {6'd0, internal_offset};
        endcase
    end

    always @(*) begin
        case (sg)
            3'd1:    resylen = 11'd384;
            3'd2:    resylen = 11'd768;
            3'd3:    resylen = 11'd1536;
            3'd4:    resylen = 11'd1152;
            3'd5:    resylen = 11'd1536;
            default: resylen = 11'd384;
        endcase
    end

    // -------------------------------------------------------------------------
    // FSM Control 
    // -------------------------------------------------------------------------
    assign prbs11_en = (state == ST_GEN_PRBS);

    always @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            bit_cnt          <= 11'd0;
            tx_cnt           <= 11'd0;
            prbs9_en         <= 1'b0;
            ready            <= 1'b1;
            valid            <= 1'b0;
            header_done      <= 1'b0;
            tx_phy_rsync_hdr <= 1'b0;
            sy_double_shift  <= 80'd0;
            sy_shift         <= 40'd0;
            ptb_shift        <= 16'd0;
        end else begin
            header_done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    valid            <= 1'b0;
                    tx_phy_rsync_hdr <= 1'b0;
                    prbs9_en         <= 1'b0;

                    if (req) begin
                        ready    <= 1'b0;
                        state    <= ST_GEN_PRBS;
                        bit_cnt  <= 11'd0;
                        prbs9_en <= 1'b1;

                        // Load the rotators with the initial static values
                        sy_double_shift <= sy_double_rev;
                        sy_shift        <= sy_rev;
                        ptb_shift       <= m_ptb;
                    end else begin
                        ready    <= 1'b1;
                    end
                end

                ST_GEN_PRBS: begin
                    prbs9_en <= 1'b0;
                    
                    if (bit_cnt == 11'd1535) begin
                        state  <= ST_STREAM;
                        tx_cnt <= 11'd0;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                ST_STREAM: begin
                    valid <= 1'b1;

                    if (sg == 3'd1 || sg == 3'd2) begin
                        // --- Equation 4-1 ---
                        if (tx_cnt < n) begin
                            tx_phy_rsync_hdr <= prbs_stream_out;
                        end else if (tx_cnt < (n + 11'd80)) begin
                            tx_phy_rsync_hdr <= sy_double_shift[0];
                            sy_double_shift  <= {sy_double_shift[0], sy_double_shift[79:1]}; 
                        end else if (tx_cnt < m) begin
                            tx_phy_rsync_hdr <= prbs_stream_out;
                        end else if (tx_cnt < (m + 11'd40)) begin
                            tx_phy_rsync_hdr <= sy_shift[0];
                            sy_shift         <= {sy_shift[0], sy_shift[39:1]};              
                        end else if (tx_cnt < (resylen - 11'd32)) begin
                            tx_phy_rsync_hdr <= prbs_stream_out;
                        end else if (tx_cnt < (resylen - 11'd16)) begin
                            tx_phy_rsync_hdr <= ptb_shift[0];
                            ptb_shift        <= {ptb_shift[0], ptb_shift[15:1]};             
                        end else begin
                            tx_phy_rsync_hdr <= ~ptb_shift[0];                               // Inverted PTB
                            ptb_shift        <= {ptb_shift[0], ptb_shift[15:1]};             
                        end
                    end else begin
                        // --- Equation 4-2 ---
                        if (tx_cnt < n) begin
                            tx_phy_rsync_hdr <= prbs_stream_out;
                        end else if (tx_cnt < (n + 11'd160)) begin
                            tx_phy_rsync_hdr <= sy_double_shift[0];
                            sy_double_shift  <= {sy_double_shift[0], sy_double_shift[79:1]}; // Rotates seamlessly for 160 cycles
                        end else if (tx_cnt < m) begin
                            tx_phy_rsync_hdr <= prbs_stream_out;
                        end else if (tx_cnt < (m + 11'd80)) begin
                            tx_phy_rsync_hdr <= sy_shift[0];
                            sy_shift         <= {sy_shift[0], sy_shift[39:1]};               // Rotates seamlessly for 80 cycles
                        end else if (tx_cnt < (resylen - 11'd32)) begin
                            tx_phy_rsync_hdr <= prbs_stream_out;
                        end else if (tx_cnt < (resylen - 11'd16)) begin
                            tx_phy_rsync_hdr <= ptb_shift[0];
                            ptb_shift        <= {ptb_shift[0], ptb_shift[15:1]};
                        end else begin
                            tx_phy_rsync_hdr <= ~ptb_shift[0];
                            ptb_shift        <= {ptb_shift[0], ptb_shift[15:1]};
                        end
                    end

                    if (tx_cnt == (resylen - 1'b1)) begin
                        state <= ST_IDLE;
                         header_done <= 1'b1;
                    end else begin
                        tx_cnt <= tx_cnt + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Submodule Instantiations
    // -------------------------------------------------------------------------
    
    
    asa_prbs_buffer u_prbs_buffer (
        .clk            (clk),
        .rst_n          (rst_n),
        .load_en        (state == ST_GEN_PRBS),
        .shift_en       (state == ST_STREAM),
        .prbs11_bit_in  (prbs11_bit),
        .prbs_bit_out   (prbs_stream_out)
    );

    asa_sync_sequence u_sync_seq (
        .sy             (sy_fwd),
        .sy_double      (sy_double_fwd)
    );

    asa_resync_prbs11 u_prbs11 (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (prbs11_en),
        .prbs_out       (prbs11_bit)
    );

    prbs9_dither_source u_dither_source (
        .clk            (clk),
        .rst_n          (rst_n),
        .startup_init   (startup_init),
        .enable         (prbs9_en),
        .offset         (internal_offset)
    );

endmodule
