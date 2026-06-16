// ============================================================================
// File        : ea_ml_fvec.v
// Project     : Edge Analytics IP - PYNQ-Z2
//
// Description : ML feature vector assembler + AXI4 DMA writer.
//               FIXED: AXI4 W-channel beat counter:
//               - WLAST asserted on the LAST beat WITH WVALID=1 (not cleared)
//               - WVALID cleared only AFTER WLAST is seen with WREADY
//               - beat index advanced correctly so last word is fully sent
// ============================================================================

module ea_ml_fvec #(
    parameter DATA_W      = 16,
    parameter FEAT_W      = 32,
    parameter FFT_MAX_LOG = 7,
    parameter NORM_SHIFT  = 8
)(
    input  wire clk_i,
    input  wire rst_ni,
    input  wire enable_i,
    input  wire enable_norm_i,
    input  wire fused_valid_i,

    input  wire signed [FEAT_W-1:0] mean_i,
    input  wire        [FEAT_W-1:0] var_i,
    input  wire        [FEAT_W-1:0] peak_i,
    input  wire        [FEAT_W-1:0] rms_i,
    input  wire        [FEAT_W-1:0] zcr_i,
    input  wire signed [FEAT_W-1:0] skew_i,
    input  wire        [FEAT_W-1:0] kurt_i,
    input  wire        [FEAT_W-1:0] crest_i,
    input  wire        [FEAT_W-1:0] shape_i,
    input  wire        [FEAT_W-1:0] spec_flat_i,
    input  wire        [FEAT_W-1:0] spec_cent_i,
    input  wire [FFT_MAX_LOG-1:0]   fund_bin_i,
    input  wire [FEAT_W-1:0]        fund_mag_i,

    input  wire [1:0]        anom_severity_i,
    input  wire [DATA_W-1:0] anom_mag_i,
    input  wire [1:0]        dec_state_i,
    input  wire [7:0]        dec_conf_i,

    input  wire [31:0] dma_base_addr_i,

    output reg [31:0] m_axi_awaddr,
    output reg [7:0]  m_axi_awlen,
    output reg [2:0]  m_axi_awsize,
    output reg [1:0]  m_axi_awburst,
    output reg        m_axi_awvalid,
    input  wire       m_axi_awready,

    output reg [31:0] m_axi_wdata,
    output reg [3:0]  m_axi_wstrb,
    output reg        m_axi_wlast,
    output reg        m_axi_wvalid,
    input  wire       m_axi_wready,

    input  wire [1:0] m_axi_bresp,
    input  wire       m_axi_bvalid,
    output reg        m_axi_bready,

    output reg [7:0] frame_count_o,
    output reg       fvec_ready_o
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam FVEC_WORDS = 16;
    localparam FVEC_BYTES = 64;

    localparam IDX_MEAN       = 0;
    localparam IDX_VAR        = 1;
    localparam IDX_PEAK       = 2;
    localparam IDX_RMS        = 3;
    localparam IDX_ZCR        = 4;
    localparam IDX_SKEW       = 5;
    localparam IDX_KURT       = 6;
    localparam IDX_CREST      = 7;
    localparam IDX_SHAPE      = 8;
    localparam IDX_SPEC_FLAT  = 9;
    localparam IDX_SPEC_CENT  = 10;
    localparam IDX_FUND_BIN   = 11;
    localparam IDX_FUND_MAG   = 12;
    localparam IDX_ANOM       = 13;
    localparam IDX_DEC        = 14;
    localparam IDX_TS         = 15;

    // =========================================================================
    // Feature buffer + frame counter
    // =========================================================================
    reg [31:0] fbuf [0:FVEC_WORDS-1];
    reg [31:0] frame_ctr;

    function [31:0] norm_word;
        input [FEAT_W-1:0] v;
        input do_norm;
        begin
            norm_word = do_norm ? (v >> NORM_SHIFT) : v;
        end
    endfunction

    // =========================================================================
    // Frame assembly
    // =========================================================================
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            frame_ctr <= 0;
        end
        else if (fused_valid_i && enable_i) begin
            fbuf[IDX_MEAN]      <= norm_word(mean_i, enable_norm_i);
            fbuf[IDX_VAR]       <= var_i;
            fbuf[IDX_PEAK]      <= peak_i;
            fbuf[IDX_RMS]       <= rms_i;
            fbuf[IDX_ZCR]       <= zcr_i;
            fbuf[IDX_SKEW]      <= norm_word(skew_i, enable_norm_i);
            fbuf[IDX_KURT]      <= kurt_i;
            fbuf[IDX_CREST]     <= crest_i;
            fbuf[IDX_SHAPE]     <= shape_i;
            fbuf[IDX_SPEC_FLAT] <= spec_flat_i;
            fbuf[IDX_SPEC_CENT] <= spec_cent_i;
            fbuf[IDX_FUND_BIN]  <= {{(32-FFT_MAX_LOG){1'b0}}, fund_bin_i};
            fbuf[IDX_FUND_MAG]  <= norm_word(fund_mag_i, enable_norm_i);
            fbuf[IDX_ANOM]      <= {anom_severity_i, 14'd0, anom_mag_i};
            fbuf[IDX_DEC]       <= {dec_state_i, dec_conf_i, 14'd0, frame_ctr[7:0]};
            fbuf[IDX_TS]        <= frame_ctr;

            frame_ctr <= frame_ctr + 1;
        end
    end

    // =========================================================================
    // AXI FSM
    // =========================================================================
    localparam IDLE = 2'd0,
               AW   = 2'd1,
               W    = 2'd2,
               B    = 2'd3;

    reg [1:0] state;
    reg [3:0] beat;          // current beat index (0..FVEC_WORDS-1)
    reg       transfer_req;

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            state         <= IDLE;
            beat          <= 0;
            transfer_req  <= 0;

            m_axi_awvalid <= 0;
            m_axi_wvalid  <= 0;
            m_axi_wlast   <= 0;
            m_axi_bready  <= 0;

            m_axi_awlen   <= FVEC_WORDS - 1;   // 15 beats (0-indexed)
            m_axi_awsize  <= 3'd2;              // 4 bytes per beat
            m_axi_awburst <= 2'b01;             // INCR
            m_axi_wstrb   <= 4'hF;

            m_axi_awaddr  <= 0;
            m_axi_wdata   <= 0;

            frame_count_o <= 0;
            fvec_ready_o  <= 0;
        end
        else begin
            fvec_ready_o <= 0;

            // Capture transfer request
            if (fused_valid_i && enable_i)
                transfer_req <= 1;

            case (state)

                // =============================================================
                // IDLE: wait for a pending transfer, issue AW
                // =============================================================
                IDLE: begin
                    if (transfer_req) begin
                        transfer_req  <= 0;
                        m_axi_awaddr  <= dma_base_addr_i +
                                         (frame_ctr * FVEC_BYTES);
                        m_axi_awvalid <= 1;
                        state         <= AW;
                    end
                end

                // =============================================================
                // AW: wait for AWREADY, then pre-load first beat and start W
                // =============================================================
                AW: begin
                    if (m_axi_awready) begin
                        m_axi_awvalid <= 0;
                        beat          <= 0;

                        // Pre-load beat 0
                        m_axi_wdata  <= fbuf[0];
                        m_axi_wlast  <= (FVEC_WORDS == 1);  // edge case: 1-word burst
                        m_axi_wvalid <= 1;

                        state <= W;
                    end
                end

                // =============================================================
                // W: stream beats - FIX:
                //    On each accepted beat (wready && wvalid):
                //      - advance beat pointer
                //      - pre-load NEXT word
                //      - assert WLAST with WVALID=1 on the final beat
                //      - only clear WVALID after the final beat is accepted
                // =============================================================
                W: begin
                    if (m_axi_wready && m_axi_wvalid) begin
                        if (beat == FVEC_WORDS - 1) begin
                            // Last beat accepted - transaction complete
                            m_axi_wvalid <= 0;
                            m_axi_wlast  <= 0;
                            m_axi_bready <= 1;
                            state        <= B;
                        end
                        else begin
                            // Advance to next beat
                            beat         <= beat + 1'b1;
                            m_axi_wdata  <= fbuf[beat + 1'b1];
                            // Assert WLAST on the PENULTIMATE acceptance so it
                            // is presented WITH the last data beat
                            m_axi_wlast  <= (beat == FVEC_WORDS - 2);
                            // WVALID stays 1
                        end
                    end
                end

                // =============================================================
                // B: wait for write response
                // =============================================================
                B: begin
                    if (m_axi_bvalid) begin
                        m_axi_bready  <= 0;
                        frame_count_o <= frame_count_o + 1;
                        fvec_ready_o  <= 1;
                        state         <= IDLE;
                    end
                end

            endcase
        end
    end

endmodule
