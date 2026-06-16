// =============================================================================
// Module      : ea_decision
// Description : Four-state decision FSM that classifies system health based on
//               fused feature and anomaly inputs.
//
//               State encoding:
//                 2'd0  DEC_NORMAL   — All metrics within bounds
//                 2'd1  DEC_WARNING  — Soft threshold exceeded
//                 2'd2  DEC_ALERT    — Hard threshold or anomaly flag active
//                 2'd3  DEC_CRITICAL — Alert sustained for >= crit_dwell_i cycles
//
//               Transitions:
//                 NORMAL   → WARNING  : soft threshold crossed
//                 NORMAL   → ALERT    : hard threshold / anomaly flag
//                 WARNING  → NORMAL   : all conditions clear
//                 WARNING  → ALERT    : hard threshold / anomaly flag
//                 ALERT    → WARNING  : condition drops to soft
//                 ALERT    → NORMAL   : all conditions clear
//                 ALERT    → CRITICAL : dwell counter saturates
//                 CRITICAL → WARNING  : condition drops to soft
//                 CRITICAL → NORMAL   : all conditions clear
//
//               A 32-bit rolling history register packs
//               {ts_cnt[1:0], state[1:0]} per valid cycle for debug.
// =============================================================================

module ea_decision #(
    parameter integer DATA_W = 16,
    parameter integer FEAT_W = 32
)(
    // -------------------------------------------------------------------------
    // Clock and Reset
    // -------------------------------------------------------------------------
    input  wire clk_i,
    input  wire rst_ni,
    input  wire enable_i,

    // -------------------------------------------------------------------------
    // Fused Feature Inputs
    // -------------------------------------------------------------------------
    input  wire signed [FEAT_W-1:0] feat_mean_i,
    input  wire        [FEAT_W-1:0] feat_rms_i,
    input  wire        [FEAT_W-1:0] feat_peak_i,
    input  wire        [FEAT_W-1:0] feat_crest_i,
    input  wire        [FEAT_W-1:0] fft_fund_mag_i,
    input  wire                     fused_valid_i,

    // -------------------------------------------------------------------------
    // Anomaly Detector Inputs
    // -------------------------------------------------------------------------
    input  wire              anom_flag_i,
    input  wire [1:0]        anom_severity_i,
    input  wire [DATA_W-1:0] anom_mag_i,

    // -------------------------------------------------------------------------
    // Threshold Configuration
    // -------------------------------------------------------------------------
    input  wire [DATA_W-1:0] threshold_i,
    input  wire [3:0]        crit_dwell_i,   // Cycles in ALERT before → CRITICAL

    // -------------------------------------------------------------------------
    // Decision Outputs
    // -------------------------------------------------------------------------
    output reg [1:0]  dec_state_o,
    output reg        dec_valid_o,
    output reg [31:0] dec_hist_o,            // Rolling {ts_cnt[1:0], state[1:0]}
    output reg [7:0]  dec_conf_o             // Saturated confidence score
);

// =============================================================================
// State Encoding
// =============================================================================

localparam [1:0] DEC_NORMAL   = 2'd0;
localparam [1:0] DEC_WARNING  = 2'd1;
localparam [1:0] DEC_ALERT    = 2'd2;
localparam [1:0] DEC_CRITICAL = 2'd3;

// =============================================================================
// Anomaly Severity Encoding
// =============================================================================

localparam [1:0] ANOM_LOW      = 2'd0;
localparam [1:0] ANOM_MODERATE = 2'd1;
localparam [1:0] ANOM_HIGH     = 2'd2;
localparam [1:0] ANOM_SEVERE   = 2'd3;

// =============================================================================
// Internal Registers
// =============================================================================

reg [1:0]  state;
reg [3:0]  dwell_cnt;
reg [31:0] ts_cnt;

// =============================================================================
// Combinatorial Threshold Helpers
// =============================================================================

wire [FEAT_W-1:0] thresh_half = threshold_i >> 1;
wire [FEAT_W-1:0] abs_mean    = feat_mean_i[FEAT_W-1] ? -feat_mean_i : feat_mean_i;

// =============================================================================
// Transition Condition Wires
// =============================================================================

// Hard condition — any of these forces at least ALERT
wire cond_alert =  anom_flag_i
                | (anom_severity_i >= ANOM_MODERATE)
                | (feat_peak_i     >  threshold_i)
                | (fft_fund_mag_i  >  threshold_i);

// Soft condition — only when hard is not active
wire cond_warn  = ~cond_alert
                & ((feat_rms_i      > thresh_half)
                |  (abs_mean        > thresh_half)
                |  (fft_fund_mag_i  > thresh_half));

// All-clear — neither hard nor soft condition present
wire cond_clear = ~cond_alert & ~cond_warn;

// =============================================================================
// Confidence Score
// =============================================================================

// Sum of RMS, |mean|, and anomaly magnitude (wider accumulator to avoid overflow)
wire [FEAT_W+8:0] conf_raw = feat_rms_i + abs_mean + anom_mag_i;

// Saturate to 8-bit output
wire [7:0] conf_sat = (conf_raw > 16'd1023) ? 8'hFF : conf_raw[10:3];

// =============================================================================
// Main FSM
// =============================================================================

always @(posedge clk_i) begin

    // -------------------------------------------------------------------------
    // Reset
    // -------------------------------------------------------------------------
    if (!rst_ni) begin
        state       <= DEC_NORMAL;
        dec_state_o <= DEC_NORMAL;
        dec_valid_o <= 1'b0;
        dec_hist_o  <= 32'b0;
        dec_conf_o  <= 8'b0;
        dwell_cnt   <= 4'd0;
        ts_cnt      <= 32'd0;
    end

    // -------------------------------------------------------------------------
    // Normal Operation
    // -------------------------------------------------------------------------
    else begin

        ts_cnt      <= ts_cnt + 1'b1;
        dec_valid_o <= 1'b0;

        // Hold NORMAL when disabled
        if (!enable_i) begin
            state       <= DEC_NORMAL;
            dec_state_o <= DEC_NORMAL;
            dwell_cnt   <= 4'd0;
        end

        // Process one decision per valid fused feature vector
        if (fused_valid_i && enable_i) begin

            dec_conf_o  <= conf_sat;
            dec_valid_o <= 1'b1;

            // -----------------------------------------------------------------
            // State Transitions
            // -----------------------------------------------------------------
            case (state)

                DEC_NORMAL: begin
                    if      (cond_alert) state <= DEC_ALERT;
                    else if (cond_warn)  state <= DEC_WARNING;
                end

                DEC_WARNING: begin
                    if      (cond_alert) state <= DEC_ALERT;
                    else if (cond_clear) state <= DEC_NORMAL;
                end

                DEC_ALERT: begin
                    if (cond_clear) begin
                        state     <= DEC_NORMAL;
                        dwell_cnt <= 4'd0;
                    end
                    else if (cond_warn) begin
                        state     <= DEC_WARNING;
                        dwell_cnt <= 4'd0;
                    end
                    else begin
                        // Increment dwell counter and promote to CRITICAL
                        if (dwell_cnt < crit_dwell_i)
                            dwell_cnt <= dwell_cnt + 1'b1;

                        if (dwell_cnt >= crit_dwell_i - 1'b1)
                            state <= DEC_CRITICAL;
                    end
                end

                DEC_CRITICAL: begin
                    if (cond_clear) begin
                        state     <= DEC_NORMAL;
                        dwell_cnt <= 4'd0;
                    end
                    else if (cond_warn) begin
                        state     <= DEC_WARNING;
                        dwell_cnt <= 4'd0;
                    end
                end

                default: state <= DEC_NORMAL;

            endcase

            // Registered output — reflects state after this cycle's transition
            dec_state_o <= state;

            // Rolling history: pack timestamp[1:0] and current state[1:0]
            dec_hist_o <= {dec_hist_o[25:0], ts_cnt[1:0], state};

        end
    end
end

// =============================================================================
endmodule
// =============================================================================
