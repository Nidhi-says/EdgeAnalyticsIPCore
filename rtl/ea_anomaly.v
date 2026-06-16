// ============================================================================
// File        : ea_anomaly.v
// Project     : Edge Analytics IP - PYNQ-Z2
//
// Description : Anomaly detection with hysteresis severity FSM.
//               FIXED: severity_n default initialised to ANOM_NONE in the
//               combinational always block so simulation tools never see X
//               on the first cycle.
// ============================================================================

module ea_anomaly #(
    parameter integer DATA_W = 16,
    parameter integer FEAT_W = 32
)(
    input  wire                       clk_i,
    input  wire                       rst_ni,
    input  wire                       enable_i,

    input  wire signed [DATA_W-1:0]   din_i,
    input  wire                       din_valid_i,

    input  wire signed [FEAT_W-1:0]   mean_i,
    input  wire        [FEAT_W-1:0]   rms_i,

    input  wire [DATA_W-1:0]          threshold_i,
    input  wire [DATA_W-1:0]          hyst_lo_i,

    output reg                        anom_flag_o,
    output reg  [1:0]                 anom_severity_o,
    output reg  [DATA_W-1:0]          anom_mag_o,
    output reg  [15:0]                anom_count_o,
    output reg  [15:0]                zscore_o
);

    // =========================================================================
    // Severity encoding
    // =========================================================================
    localparam ANOM_NONE     = 2'b00;
    localparam ANOM_MARGINAL = 2'b01;
    localparam ANOM_MODERATE = 2'b10;
    localparam ANOM_SEVERE   = 2'b11;

    // =========================================================================
    // Thresholds
    // =========================================================================
    wire [DATA_W-1:0] T1   = threshold_i;
    wire [DATA_W-1:0] T2   = threshold_i + (threshold_i >> 1);
    wire [DATA_W-1:0] T3   = threshold_i << 1;
    wire [DATA_W-1:0] T_lo = hyst_lo_i;

    // =========================================================================
    // Deviation
    // =========================================================================
    wire signed [FEAT_W-1:0] din_ext  = {{(FEAT_W-DATA_W){din_i[DATA_W-1]}}, din_i};
    wire signed [FEAT_W-1:0] dev      = din_ext - mean_i;
    wire        [FEAT_W-1:0] abs_dev  = dev[FEAT_W-1] ? (~dev + 1'b1) : dev;

    wire [DATA_W-1:0] abs_dev_trunc =
        (|abs_dev[FEAT_W-1:DATA_W]) ? {DATA_W{1'b1}} : abs_dev[DATA_W-1:0];

    // =========================================================================
    // Z-score proxy
    // =========================================================================
    wire [7:0] rms_top = rms_i[FEAT_W-1 -: 8];

    function automatic [4:0] lzc_rms;
        input [7:0] v;
        begin
            casez (v)
                8'b1???????: lzc_rms = 0;
                8'b01??????: lzc_rms = 1;
                8'b001?????: lzc_rms = 2;
                8'b0001????: lzc_rms = 3;
                8'b00001???: lzc_rms = 4;
                8'b000001??: lzc_rms = 5;
                8'b0000001?: lzc_rms = 6;
                default:     lzc_rms = 7;
            endcase
        end
    endfunction

    wire [4:0]    rms_lzc    = lzc_rms(rms_top);
    wire [FEAT_W+7:0] zscore_raw = {abs_dev, 8'b0} >> rms_lzc;
    wire [15:0]   zscore_sat =
        (|zscore_raw[FEAT_W+7:16]) ? 16'hFFFF : zscore_raw[15:0];

    // =========================================================================
    // Severity combinational FSM
    // FIX: initialise severity_n to ANOM_NONE (not to `severity`) so that
    //      simulation never sees X on cycle 0 when `severity` is uninitialised.
    //      The registered `severity` is still used for hysteresis on the
    //      transition into MARGINAL.
    // =========================================================================
    reg [1:0] severity;
    reg [1:0] severity_n;
    reg       anom_prev;

    always @(*) begin
        // FIX: default to ANOM_NONE, not to `severity`, to kill X-prop
        severity_n = ANOM_NONE;

        if (abs_dev_trunc >= T3)
            severity_n = ANOM_SEVERE;
        else if (abs_dev_trunc >= T2)
            severity_n = ANOM_MODERATE;
        else if (abs_dev_trunc >= T1)
            severity_n = ANOM_MARGINAL;
        else if (abs_dev_trunc >= T_lo)
            // Hysteresis: stay in current state between T_lo and T1
            severity_n = severity;
        // else ANOM_NONE (default above)
    end

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            severity        <= ANOM_NONE;
            anom_flag_o     <= 1'b0;
            anom_severity_o <= ANOM_NONE;
            anom_mag_o      <= 0;
            anom_count_o    <= 0;
            anom_prev       <= 0;
            zscore_o        <= 0;
        end
        else if (enable_i && din_valid_i) begin
            severity        <= severity_n;
            anom_flag_o     <= (severity_n != ANOM_NONE);
            anom_severity_o <= severity_n;
            anom_mag_o      <= abs_dev_trunc;
            zscore_o        <= zscore_sat;

            if (!anom_prev &&
                (severity_n != ANOM_NONE) &&
                !(&anom_count_o))
                anom_count_o <= anom_count_o + 1'b1;

            anom_prev <= (severity_n != ANOM_NONE);
        end
        else if (!enable_i) begin
            severity    <= ANOM_NONE;
            anom_flag_o <= 0;
        end
    end

endmodule
