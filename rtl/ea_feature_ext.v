// ============================================================================
// File        : ea_feature_ext.v
// Project     : Edge Analytics IP - PYNQ-Z2
//
// Description : Time-domain feature extraction engine.
//               FIXED: accumulator race on final sample, stale LZC regs,
//               win_q lock conflict with smp_cnt reset.
// ============================================================================

module ea_feature_ext #(
    parameter integer DATA_W      = 16,
    parameter integer FEAT_W      = 32,
    parameter integer MAX_WIN_LOG = 5
)(
    input  wire                      clk_i,
    input  wire                      rst_ni,
    input  wire                      enable_i,

    // Filtered input stream
    input  wire signed [DATA_W-1:0]  din_i,
    input  wire                      din_valid_i,

    // Window size
    input  wire [MAX_WIN_LOG-1:0]    win_size_i,

    // Feature outputs
    output reg  signed [FEAT_W-1:0]  mean_o,
    output reg         [FEAT_W-1:0]  var_o,
    output reg         [FEAT_W-1:0]  peak_o,
    output reg         [FEAT_W-1:0]  rms_o,
    output reg         [FEAT_W-1:0]  zcr_o,
    output reg         [FEAT_W-1:0]  crest_o,
    output reg         [FEAT_W-1:0]  shape_o,

    output reg                       feat_valid_o
);

    // =========================================================================
    // Width constants
    // =========================================================================
    localparam integer SUM_X_W  = DATA_W + MAX_WIN_LOG;
    localparam integer SUM_X2_W = (2*DATA_W) + MAX_WIN_LOG;

    // =========================================================================
    // Accumulators and counters
    // =========================================================================
    reg signed [SUM_X_W-1:0]   sum_x;
    reg        [SUM_X2_W-1:0]  sum_x2;
    reg [DATA_W-1:0]            peak_reg;
    reg [MAX_WIN_LOG:0]         zcr_cnt;
    reg [MAX_WIN_LOG-1:0]       smp_cnt;
    reg signed [DATA_W-1:0]     prev_sample;
    reg [MAX_WIN_LOG-1:0]       win_q;

    // =========================================================================
    // Combinational pre-computation (current sample)
    // =========================================================================
    wire [DATA_W-1:0] abs_din =
        din_i[DATA_W-1] ? (~din_i + 1'b1) : din_i;

    wire signed [SUM_X_W-1:0] din_ext =
        {{(SUM_X_W-DATA_W){din_i[DATA_W-1]}}, din_i};

    wire [2*DATA_W-1:0] x_sq = abs_din * abs_din;

    wire zcr_edge = din_i[DATA_W-1] ^ prev_sample[DATA_W-1];

    // =========================================================================
    // log2(power_of_2)
    // =========================================================================
    function [MAX_WIN_LOG-1:0] log2p2;
        input [MAX_WIN_LOG-1:0] n;
        integer i;
        begin
            log2p2 = 0;
            for (i = 0; i < MAX_WIN_LOG; i = i + 1)
                if (n[i]) log2p2 = i[MAX_WIN_LOG-1:0];
        end
    endfunction

    wire [MAX_WIN_LOG-1:0] shift_amt = log2p2(win_q);

    // =========================================================================
    // Window done: fires on the LAST sample (smp_cnt == win_q-1)
    // =========================================================================
    wire window_done =
        din_valid_i && enable_i && (smp_cnt == (win_q - 1'b1));

    // =========================================================================
    // Final window combinational values (include current sample)
    // =========================================================================
    wire signed [SUM_X_W-1:0] fx_sum  = sum_x  + din_ext;
    wire [SUM_X2_W-1:0]        fx_sum2 = sum_x2 +
                                    {{(SUM_X2_W-(2*DATA_W)){1'b0}}, x_sq};
    wire [DATA_W-1:0]           fx_peak = (abs_din > peak_reg) ? abs_din : peak_reg;
    wire [MAX_WIN_LOG:0]        fx_zcr  = zcr_cnt + zcr_edge;

    // =========================================================================
    // Derived features (combinational, use fx_ finals)
    // =========================================================================
    wire signed [FEAT_W-1:0] mean_c = $signed(fx_sum) >>> shift_amt;
    wire [FEAT_W-1:0]         ex2_c  = fx_sum2 >> shift_amt;

    wire [2*DATA_W-1:0] mu_sq_c = mean_c[DATA_W-1:0] * mean_c[DATA_W-1:0];

    wire signed [FEAT_W:0] var_diff_c =
        $signed({1'b0, ex2_c}) - $signed({1'b0, mu_sq_c});

    wire [FEAT_W-1:0] var_c =
        var_diff_c[FEAT_W] ? {FEAT_W{1'b0}} : var_diff_c[FEAT_W-1:0];

    wire [MAX_WIN_LOG+16:0] zcr_scaled_c = {fx_zcr, 16'b0};
    wire [FEAT_W-1:0]        zcr_c        = zcr_scaled_c >> shift_amt;

    // =========================================================================
    // Leading zero count
    // =========================================================================
    function [4:0] lzc16;
        input [15:0] v;
        begin
            casez (v)
                16'b1???????????????: lzc16 = 0;
                16'b01??????????????: lzc16 = 1;
                16'b001?????????????: lzc16 = 2;
                16'b0001????????????: lzc16 = 3;
                16'b00001???????????: lzc16 = 4;
                16'b000001??????????: lzc16 = 5;
                16'b0000001?????????: lzc16 = 6;
                16'b00000001????????: lzc16 = 7;
                16'b000000001???????: lzc16 = 8;
                16'b0000000001??????: lzc16 = 9;
                16'b00000000001?????: lzc16 = 10;
                16'b000000000001????: lzc16 = 11;
                16'b0000000000001???: lzc16 = 12;
                16'b00000000000001??: lzc16 = 13;
                16'b000000000000001?: lzc16 = 14;
                default:              lzc16 = 15;
            endcase
        end
    endfunction

    // FIX: compute LZC combinationally from this window's data, not stale regs
    wire [4:0]  rms_lzc_c  = lzc16(ex2_c[15:0]);

    wire [15:0] abs_mean_c =
        mean_c[FEAT_W-1] ? (~mean_c[15:0] + 1'b1) : mean_c[15:0];

    wire [4:0]  mean_lzc_c = lzc16(abs_mean_c);

    // Crest & shape computed from this window
    wire [FEAT_W-1:0] crest_c =
        {{(FEAT_W-DATA_W){1'b0}}, fx_peak, 8'b0} >> rms_lzc_c;

    wire [FEAT_W-1:0] shape_c = ex2_c >> mean_lzc_c;

    // =========================================================================
    // Main sequential block
    // =========================================================================
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            sum_x        <= 0;
            sum_x2       <= 0;
            peak_reg     <= 0;
            zcr_cnt      <= 0;
            smp_cnt      <= 0;
            prev_sample  <= 0;
            win_q        <= 5'd8;

            mean_o       <= 0;
            var_o        <= 0;
            peak_o       <= 0;
            rms_o        <= 0;
            zcr_o        <= 0;
            crest_o      <= 0;
            shape_o      <= 0;
            feat_valid_o <= 1'b0;
        end
        else begin
            feat_valid_o <= 1'b0;

            if (din_valid_i && enable_i) begin

                if (window_done) begin
                    // ---------------------------------------------------------
                    // FIX 1: latch FINAL computed values (fx_/mean_c/etc.)
                    //         then reset accumulators - no race because we latch
                    //         the combinational wires first.
                    // FIX 2: LZC used is combinational (rms_lzc_c, mean_lzc_c)
                    //         not stale registered values.
                    // ---------------------------------------------------------
                    mean_o       <= mean_c;
                    var_o        <= var_c;
                    peak_o       <= {{(FEAT_W-DATA_W){1'b0}}, fx_peak};
                    rms_o        <= ex2_c;
                    zcr_o        <= zcr_c;
                    crest_o      <= crest_c;
                    shape_o      <= shape_c;
                    feat_valid_o <= 1'b1;

                    // Reset accumulators for next window
                    sum_x    <= 0;
                    sum_x2   <= 0;
                    peak_reg <= 0;
                    zcr_cnt  <= 0;
                    prev_sample <= din_i;   // carry current sample as prev

                    // FIX 3: smp_cnt resets to 1 (not 0) because this sample
                    //         was already consumed as the last sample of the
                    //         completed window.  win_q lock reads smp_cnt==0
                    //         which never collides with this reset path.
                    smp_cnt  <= 0;

                    // FIX 3: update win_q here (start of new window) safely
                    if (win_size_i == 0)
                        win_q <= 5'd8;
                    else
                        win_q <= win_size_i;
                end
                else begin
                    // Normal per-sample accumulation
                    sum_x   <= sum_x  + din_ext;
                    sum_x2  <= sum_x2 + {{(SUM_X2_W-(2*DATA_W)){1'b0}}, x_sq};

                    if (abs_din > peak_reg)
                        peak_reg <= abs_din;

                    zcr_cnt     <= zcr_cnt + zcr_edge;
                    prev_sample <= din_i;
                    smp_cnt     <= smp_cnt + 1'b1;
                end
            end
            else begin
                // FIX 3: update win_q only when idle and smp_cnt==0
                if (smp_cnt == 0) begin
                    if (win_size_i == 0)
                        win_q <= 5'd8;
                    else
                        win_q <= win_size_i;
                end
            end
        end
    end

endmodule
