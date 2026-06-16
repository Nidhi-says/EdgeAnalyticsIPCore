// =============================================================================
// Module      : ea_top
// Description : Top-level entity analysis module. Instantiates stimulus
//               generation, MA filter, feature extractor, FFT engine,
//               anomaly detector, decision logic, and ML feature vector
//               DMA writer.
// =============================================================================

module ea_top #(
    parameter integer DATA_W       = 16,
    parameter integer FIFO_DEPTH   = 256,   // Kept for compatibility (unused)
    parameter integer MAX_WIN_LOG  = 5,
    parameter integer FEAT_W       = 32,
    parameter integer FFT_MAX_LOG  = 7,
    parameter integer SPIKE_PERIOD = 256,
    parameter integer NORM_SHIFT   = 8
)(
    // -------------------------------------------------------------------------
    // Clock and Reset
    // -------------------------------------------------------------------------
    input  wire clk_i,
    input  wire rst_ni,

    // -------------------------------------------------------------------------
    // Control
    // -------------------------------------------------------------------------
    input  wire ctrl_enable_i,
    input  wire ctrl_soft_rst_i,
    input  wire ctrl_filt_bypass_i,
    input  wire ctrl_feat_en_i,
    input  wire ctrl_anom_en_i,
    input  wire ctrl_dec_en_i,
    input  wire ctrl_fft_en_i,
    input  wire ctrl_ml_en_i,
    input  wire ctrl_stim_en_i,

    // -------------------------------------------------------------------------
    // Stimulus Generator Configuration
    // -------------------------------------------------------------------------
    input  wire [1:0]  stim_mode_i,
    input  wire [15:0] stim_rate_i,
    input  wire [15:0] stim_amp_i,
    input  wire [15:0] stim_freq_i,

    // -------------------------------------------------------------------------
    // AXI4-Stream Slave (data input)
    // -------------------------------------------------------------------------
    input  wire [DATA_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire              s_axis_tlast,

    // -------------------------------------------------------------------------
    // Window / FFT Size
    // -------------------------------------------------------------------------
    input  wire [MAX_WIN_LOG-1:0] win_size_i,
    input  wire [1:0]             fft_size_i,

    // -------------------------------------------------------------------------
    // Anomaly Thresholds
    // -------------------------------------------------------------------------
    input  wire [DATA_W-1:0] threshold_i,
    input  wire [DATA_W-1:0] hyst_lo_i,
    input  wire [3:0]        crit_dwell_i,

    // -------------------------------------------------------------------------
    // ML / DMA Configuration
    // -------------------------------------------------------------------------
    input  wire [31:0] ml_base_addr_i,
    input  wire        ml_norm_en_i,

    // -------------------------------------------------------------------------
    // Filter Outputs
    // -------------------------------------------------------------------------
    output wire signed [DATA_W-1:0] filt_data_o,
    output wire                     filt_valid_o,
    output wire [7:0]               fifo_occ_o,

    // -------------------------------------------------------------------------
    // Feature Extractor Outputs
    // -------------------------------------------------------------------------
    output wire signed [FEAT_W-1:0] feat_mean_o,
    output wire        [FEAT_W-1:0] feat_var_o,
    output wire        [FEAT_W-1:0] feat_peak_o,
    output wire        [FEAT_W-1:0] feat_rms_o,
    output wire        [FEAT_W-1:0] feat_zcr_o,
    output wire        [FEAT_W-1:0] feat_crest_o,
    output wire        [FEAT_W-1:0] feat_shape_o,
    output wire                     feat_valid_o,

    // -------------------------------------------------------------------------
    // FFT Engine Outputs
    // -------------------------------------------------------------------------
    output wire [FFT_MAX_LOG-1:0] fft_fund_bin_o,
    output wire [FEAT_W-1:0]      fft_fund_mag_o,
    output wire [FEAT_W-1:0]      fft_dc_mag_o,
    output wire [FEAT_W-1:0]      fft_spec_cent_o,
    output wire                   fft_done_o,

    // -------------------------------------------------------------------------
    // Anomaly Detector Outputs
    // -------------------------------------------------------------------------
    output wire                  anom_flag_o,
    output wire [1:0]            anom_severity_o,
    output wire [DATA_W-1:0]     anom_mag_o,
    output wire [15:0]           anom_count_o,
    output wire [15:0]           anom_zscore_o,

    // -------------------------------------------------------------------------
    // Decision Engine Outputs
    // -------------------------------------------------------------------------
    output wire [1:0]  dec_state_o,
    output wire        dec_valid_o,
    output wire [31:0] dec_hist_o,
    output wire [7:0]  dec_conf_o,

    // -------------------------------------------------------------------------
    // ML Feature Vector Outputs
    // -------------------------------------------------------------------------
    output wire [7:0] ml_frame_count_o,
    output wire       ml_fvec_ready_o,
    output wire       irq_o,

    // -------------------------------------------------------------------------
    // AXI4 Master (DMA write channel)
    // -------------------------------------------------------------------------
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,

    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,

    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready
);

// =============================================================================
// Internal Reset
// =============================================================================

wire rst_int_n = rst_ni & ~ctrl_soft_rst_i;

// =============================================================================
// Internal Wires — Stimulus Generator
// =============================================================================

wire [DATA_W-1:0] stim_tdata;
wire              stim_tvalid;
wire              stim_tready;

// =============================================================================
// AXI-Stream Input Mux (stimulus vs. external)
// =============================================================================

wire [DATA_W-1:0] axis_tdata  = ctrl_stim_en_i ? stim_tdata  : s_axis_tdata;
wire              axis_tvalid = ctrl_stim_en_i ? stim_tvalid : s_axis_tvalid;
wire              axis_tready;

assign s_axis_tready = axis_tready;

// =============================================================================
// Internal Wires — Filter
// =============================================================================

wire signed [DATA_W-1:0] filt_data;
wire                     filt_valid;

// =============================================================================
// Internal Wires — Feature Extractor
// =============================================================================

wire signed [FEAT_W-1:0] feat_mean;
wire        [FEAT_W-1:0] feat_var;
wire        [FEAT_W-1:0] feat_peak;
wire signed [FEAT_W-1:0] feat_rms;
wire        [FEAT_W-1:0] feat_zcr;
wire        [FEAT_W-1:0] feat_crest;
wire        [FEAT_W-1:0] feat_shape;
wire                     feat_valid;

// =============================================================================
// Internal Wires — FFT Engine
// =============================================================================

wire [FFT_MAX_LOG-1:0] fft_bin;
wire [FEAT_W-1:0]      fft_mag;
wire [FEAT_W-1:0]      fft_dc;
wire [FEAT_W-1:0]      fft_cent;
wire                   fft_done;

// =============================================================================
// Internal Wires — Anomaly Detector
// =============================================================================

wire              anom_flag;
wire [1:0]        anom_sev;
wire [DATA_W-1:0] anom_mag;
wire [15:0]       anom_cnt;
wire [15:0]       anom_z;

// =============================================================================
// Internal Wires — Decision Engine
// =============================================================================

wire [1:0]  dec_state;
wire        dec_valid;
wire [31:0] dec_hist;
wire [7:0]  dec_conf;

// =============================================================================
// Internal Wires — ML Feature Vector
// =============================================================================

wire [7:0] ml_frame_count;
wire       ml_ready;

// =============================================================================
// Instance : ea_stim_gen — Stimulus Generator
// =============================================================================

ea_stim_gen #(
    .DATA_W      (DATA_W      ),
    .SPIKE_PERIOD(SPIKE_PERIOD)
) u_stim (
    .clk_i          (clk_i        ),
    .rst_ni         (rst_int_n    ),
    .enable_i       (ctrl_stim_en_i),
    .mode_i         (stim_mode_i  ),
    .stim_rate_i    (stim_rate_i  ),
    .stim_amp_i     (stim_amp_i   ),
    .stim_freq_i    (stim_freq_i  ),
    .m_axis_tdata   (stim_tdata   ),
    .m_axis_tvalid  (stim_tvalid  ),
    .m_axis_tready  (stim_tready  )
);

// =============================================================================
// Instance : ea_ma_filter — Moving-Average Filter
// =============================================================================

ea_ma_filter #(
    .DATA_W     (DATA_W     ),
    .MAX_WIN_LOG(MAX_WIN_LOG)
) u_ma (
    .clk_i       (clk_i            ),
    .rst_ni      (rst_int_n        ),
    .din_i       (axis_tdata       ),
    .din_valid_i (axis_tvalid      ),
    .win_size_i  (win_size_i       ),
    .bypass_i    (ctrl_filt_bypass_i),
    .dout_o      (filt_data        ),
    .dout_valid_o(filt_valid       ),
    .rd_en_o     (axis_tready      )
);

// FIFO occupancy removed — tied to zero
assign fifo_occ_o = 8'd0;

// =============================================================================
// Instance : ea_feature_ext — Feature Extractor
// =============================================================================

ea_feature_ext u_feat (
    .clk_i       (clk_i        ),
    .rst_ni      (rst_int_n    ),
    .enable_i    (ctrl_feat_en_i),
    .din_i       (filt_data    ),
    .din_valid_i (filt_valid   ),
    .win_size_i  (win_size_i   ),
    .mean_o      (feat_mean    ),
    .var_o       (feat_var     ),
    .peak_o      (feat_peak    ),
    .rms_o       (feat_rms     ),
    .zcr_o       (feat_zcr     ),
    .crest_o     (feat_crest   ),
    .shape_o     (feat_shape   ),
    .feat_valid_o(feat_valid   )
);

// =============================================================================
// Instance : ea_fft_engine — FFT Engine
// =============================================================================

ea_fft_engine u_fft (
    .clk_i      (clk_i       ),
    .rst_ni     (rst_int_n   ),
    .enable_i   (ctrl_fft_en_i),
    .din_i      (filt_data   ),
    .din_valid_i(filt_valid  ),
    .fft_size_i (fft_size_i  ),
    .fund_bin_o (fft_bin     ),
    .fund_mag_o (fft_mag     ),
    .dc_mag_o   (fft_dc      ),
    .spec_cent_o(fft_cent    ),
    .done_o     (fft_done    )
);

// =============================================================================
// Instance : ea_anomaly — Anomaly Detector
// =============================================================================

ea_anomaly u_anom (
    .clk_i         (clk_i        ),
    .rst_ni        (rst_int_n    ),
    .enable_i      (ctrl_anom_en_i),
    .din_i         (filt_data    ),
    .din_valid_i   (filt_valid   ),
    .mean_i        (feat_mean    ),
    .rms_i         (feat_rms     ),
    .threshold_i   (threshold_i  ),
    .hyst_lo_i     (hyst_lo_i    ),
    .anom_flag_o   (anom_flag    ),
    .anom_severity_o(anom_sev   ),
    .anom_mag_o    (anom_mag     ),
    .anom_count_o  (anom_cnt     ),
    .zscore_o      (anom_z       )
);

// =============================================================================
// Instance : ea_decision — Decision Engine
// =============================================================================

ea_decision u_dec (
    .clk_i         (clk_i        ),
    .rst_ni        (rst_int_n    ),
    .enable_i      (ctrl_dec_en_i),
    .feat_mean_i   (feat_mean    ),
    .feat_rms_i    (feat_rms     ),
    .feat_peak_i   (feat_peak    ),
    .feat_crest_i  (feat_crest   ),
    .fft_fund_mag_i(fft_mag      ),
    .fused_valid_i (feat_valid   ),
    .anom_flag_i   (anom_flag    ),
    .anom_severity_i(anom_sev   ),
    .anom_mag_i    (anom_mag     ),
    .threshold_i   (threshold_i  ),
    .crit_dwell_i  (crit_dwell_i ),
    .dec_state_o   (dec_state    ),
    .dec_valid_o   (dec_valid    ),
    .dec_hist_o    (dec_hist     ),
    .dec_conf_o    (dec_conf     )
);

// =============================================================================
// Instance : ea_ml_fvec — ML Feature Vector / DMA Writer
// =============================================================================

ea_ml_fvec u_ml (
    .clk_i          (clk_i         ),
    .rst_ni         (rst_int_n     ),
    .enable_i       (ctrl_ml_en_i  ),
    .enable_norm_i  (ml_norm_en_i  ),
    .fused_valid_i  (feat_valid    ),
    // Feature inputs
    .mean_i         (feat_mean     ),
    .var_i          (feat_var      ),
    .peak_i         (feat_peak     ),
    .rms_i          (feat_rms      ),
    .zcr_i          (feat_zcr      ),
    .skew_i         ({FEAT_W{1'b0}}),   // Not yet implemented
    .kurt_i         ({FEAT_W{1'b0}}),   // Not yet implemented
    .crest_i        (feat_crest    ),
    .shape_i        (feat_shape    ),
    .spec_flat_i    ({FEAT_W{1'b0}}),   // Not yet implemented
    .spec_cent_i    (fft_cent      ),
    .fund_bin_i     (fft_bin       ),
    .fund_mag_i     (fft_mag       ),
    // Anomaly / decision context
    .anom_severity_i(anom_sev      ),
    .anom_mag_i     (anom_mag      ),
    .dec_state_i    (dec_state     ),
    .dec_conf_i     (dec_conf      ),
    // DMA configuration
    .dma_base_addr_i(ml_base_addr_i),
    // AXI4 master write channel
    .m_axi_awaddr   (m_axi_awaddr  ),
    .m_axi_awlen    (m_axi_awlen   ),
    .m_axi_awsize   (m_axi_awsize  ),
    .m_axi_awburst  (m_axi_awburst ),
    .m_axi_awvalid  (m_axi_awvalid ),
    .m_axi_awready  (m_axi_awready ),
    .m_axi_wdata    (m_axi_wdata   ),
    .m_axi_wstrb    (m_axi_wstrb   ),
    .m_axi_wlast    (m_axi_wlast   ),
    .m_axi_wvalid   (m_axi_wvalid  ),
    .m_axi_wready   (m_axi_wready  ),
    .m_axi_bresp    (m_axi_bresp   ),
    .m_axi_bvalid   (m_axi_bvalid  ),
    .m_axi_bready   (m_axi_bready  ),
    // Status
    .frame_count_o  (ml_frame_count),
    .fvec_ready_o   (ml_ready      )
);

// =============================================================================
// Output Assignments — Filter
// =============================================================================

assign filt_data_o  = filt_data;
assign filt_valid_o = filt_valid;

// =============================================================================
// Output Assignments — Feature Extractor
// =============================================================================

assign feat_mean_o  = feat_mean;
assign feat_var_o   = feat_var;
assign feat_peak_o  = feat_peak;
assign feat_rms_o   = feat_rms;
assign feat_zcr_o   = feat_zcr;
assign feat_crest_o = feat_crest;
assign feat_shape_o = feat_shape;
assign feat_valid_o = feat_valid;

// =============================================================================
// Output Assignments — FFT Engine
// =============================================================================

assign fft_fund_bin_o  = fft_bin;
assign fft_fund_mag_o  = fft_mag;
assign fft_dc_mag_o    = fft_dc;
assign fft_spec_cent_o = fft_cent;
assign fft_done_o      = fft_done;

// =============================================================================
// Output Assignments — Anomaly Detector
// =============================================================================

assign anom_flag_o     = anom_flag;
assign anom_severity_o = anom_sev;
assign anom_mag_o      = anom_mag;
assign anom_count_o    = anom_cnt;
assign anom_zscore_o   = anom_z;

// =============================================================================
// Output Assignments — Decision Engine
// =============================================================================

assign dec_state_o = dec_state;
assign dec_valid_o = dec_valid;
assign dec_hist_o  = dec_hist;
assign dec_conf_o  = dec_conf;

// =============================================================================
// Output Assignments — ML Feature Vector
// =============================================================================

assign ml_frame_count_o = ml_frame_count;
assign ml_fvec_ready_o  = ml_ready;

// =============================================================================
// Interrupt — Registered for clean edge to interrupt controller
// =============================================================================

reg irq_r;

always @(posedge clk_i) begin
    irq_r <= feat_valid | anom_flag | fft_done | ml_ready | dec_valid;
end

assign irq_o = irq_r;

// =============================================================================
endmodule
// =============================================================================
