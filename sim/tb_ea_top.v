module tb_ea_top;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam DATA_W      = 16;
    localparam FEAT_W      = 32;
    localparam FFT_MAX_LOG = 7;
    localparam CLK_HALF    = 5;   // 100 MHz

    // =========================================================================
    // Clock & reset
    // =========================================================================
    reg clk = 0;
    reg rst_n;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg  ctrl_enable, ctrl_soft_rst, ctrl_filt_bypass;
    reg  ctrl_feat_en, ctrl_anom_en, ctrl_dec_en;
    reg  ctrl_fft_en, ctrl_ml_en, ctrl_stim_en;

    reg  [1:0]  stim_mode;
    reg  [15:0] stim_rate, stim_amp, stim_freq;

    // --- s_axis (external data path) ---
    // When ctrl_stim_en=1 the DUT mux ignores these.
    // We drive them with a simple counter so they are never
    // X/Z in the waveform - making it easy to see the mux at work.
    reg  [DATA_W-1:0] s_axis_tdata;
    reg               s_axis_tvalid;
    wire              s_axis_tready;
    reg               s_axis_tlast;

    reg  [4:0]  win_size;
    reg  [1:0]  fft_size;

    reg  [DATA_W-1:0] threshold, hyst_lo;
    reg  [3:0]        crit_dwell;

    reg  [31:0] ml_base_addr;
    reg         ml_norm_en;

    wire signed [DATA_W-1:0] filt_data;
    wire                     filt_valid;
    wire [7:0]               fifo_occ;

    wire signed [FEAT_W-1:0] feat_mean;
    wire        [FEAT_W-1:0] feat_var, feat_peak, feat_rms;
    wire        [FEAT_W-1:0] feat_zcr, feat_crest, feat_shape;
    wire                     feat_valid;

    wire [FFT_MAX_LOG-1:0]   fft_fund_bin;
    wire [FEAT_W-1:0]        fft_fund_mag, fft_dc_mag, fft_spec_cent;
    wire                     fft_done;

    wire                     anom_flag;
    wire [1:0]               anom_sev;
    wire [DATA_W-1:0]        anom_mag;
    wire [15:0]              anom_count, anom_zscore;

    wire [1:0]  dec_state;
    wire        dec_valid;
    wire [31:0] dec_hist;
    wire [7:0]  dec_conf;

    wire [7:0]  ml_frame_count;
    wire        ml_fvec_ready;
    wire        irq;

    // AXI4 master
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    reg         m_axi_awready;

    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    reg         m_axi_wready;

    reg  [1:0]  m_axi_bresp;
    reg         m_axi_bvalid;
    wire        m_axi_bready;

    // =========================================================================
    // DUT
    // =========================================================================
    ea_top #(
        .DATA_W      (DATA_W),
        .MAX_WIN_LOG (5),
        .FEAT_W      (FEAT_W),
        .FFT_MAX_LOG (FFT_MAX_LOG),
        .SPIKE_PERIOD(64),
        .NORM_SHIFT  (8)
    ) dut (
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .ctrl_enable_i     (ctrl_enable),
        .ctrl_soft_rst_i   (ctrl_soft_rst),
        .ctrl_filt_bypass_i(ctrl_filt_bypass),
        .ctrl_feat_en_i    (ctrl_feat_en),
        .ctrl_anom_en_i    (ctrl_anom_en),
        .ctrl_dec_en_i     (ctrl_dec_en),
        .ctrl_fft_en_i     (ctrl_fft_en),
        .ctrl_ml_en_i      (ctrl_ml_en),
        .ctrl_stim_en_i    (ctrl_stim_en),
        .stim_mode_i       (stim_mode),
        .stim_rate_i       (stim_rate),
        .stim_amp_i        (stim_amp),
        .stim_freq_i       (stim_freq),
        .s_axis_tdata      (s_axis_tdata),
        .s_axis_tvalid     (s_axis_tvalid),
        .s_axis_tready     (s_axis_tready),
        .s_axis_tlast      (s_axis_tlast),
        .win_size_i        (win_size),
        .fft_size_i        (fft_size),
        .threshold_i       (threshold),
        .hyst_lo_i         (hyst_lo),
        .crit_dwell_i      (crit_dwell),
        .ml_base_addr_i    (ml_base_addr),
        .ml_norm_en_i      (ml_norm_en),
        .filt_data_o       (filt_data),
        .filt_valid_o      (filt_valid),
        .fifo_occ_o        (fifo_occ),
        .feat_mean_o       (feat_mean),
        .feat_var_o        (feat_var),
        .feat_peak_o       (feat_peak),
        .feat_rms_o        (feat_rms),
        .feat_zcr_o        (feat_zcr),
        .feat_crest_o      (feat_crest),
        .feat_shape_o      (feat_shape),
        .feat_valid_o      (feat_valid),
        .fft_fund_bin_o    (fft_fund_bin),
        .fft_fund_mag_o    (fft_fund_mag),
        .fft_dc_mag_o      (fft_dc_mag),
        .fft_spec_cent_o   (fft_spec_cent),
        .fft_done_o        (fft_done),
        .anom_flag_o       (anom_flag),
        .anom_severity_o   (anom_sev),
        .anom_mag_o        (anom_mag),
        .anom_count_o      (anom_count),
        .anom_zscore_o     (anom_zscore),
        .dec_state_o       (dec_state),
        .dec_valid_o       (dec_valid),
        .dec_hist_o        (dec_hist),
        .dec_conf_o        (dec_conf),
        .ml_frame_count_o  (ml_frame_count),
        .ml_fvec_ready_o   (ml_fvec_ready),
        .irq_o             (irq),
        .m_axi_awaddr      (m_axi_awaddr),
        .m_axi_awlen       (m_axi_awlen),
        .m_axi_awsize      (m_axi_awsize),
        .m_axi_awburst     (m_axi_awburst),
        .m_axi_awvalid     (m_axi_awvalid),
        .m_axi_awready     (m_axi_awready),
        .m_axi_wdata       (m_axi_wdata),
        .m_axi_wstrb       (m_axi_wstrb),
        .m_axi_wlast       (m_axi_wlast),
        .m_axi_wvalid      (m_axi_wvalid),
        .m_axi_wready      (m_axi_wready),
        .m_axi_bresp       (m_axi_bresp),
        .m_axi_bvalid      (m_axi_bvalid),
        .m_axi_bready      (m_axi_bready)
    );

    // =========================================================================
    // Simple AXI4 slave: always-ready, instant OKAY response
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;
        end else begin
            m_axi_awready <= 1'b1;
            m_axi_wready  <= 1'b1;
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                m_axi_bvalid <= 1'b1;
            else if (m_axi_bready)
                m_axi_bvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Drive s_axis with a visible counter so it is never X in the waveform.
    // The DUT ignores it while ctrl_stim_en=1, but it is clean to look at.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axis_tdata  <= 0;
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
        end else begin
            // Toggle valid every cycle and increment data
            s_axis_tvalid <= ~s_axis_tvalid;
            if (s_axis_tvalid)
                s_axis_tdata <= s_axis_tdata + 1;
            s_axis_tlast  <= 1'b0;
        end
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("tb_ea_top.vcd");
        $dumpvars(0, tb_ea_top);
    end

    // =========================================================================
    // Event counters & console log
    // =========================================================================
    integer feat_cnt = 0;
    integer fft_cnt  = 0;
    integer anom_ev  = 0;
    integer ml_cnt   = 0;

    always @(posedge clk) begin
        if (feat_valid) begin
            feat_cnt = feat_cnt + 1;
            $display("t=%0t [FEAT #%0d] mean=%0d var=%0d peak=%0d rms=%0d zcr=%0d crest=%0d shape=%0d",
                $time, feat_cnt,
                $signed(feat_mean), feat_var, feat_peak,
                feat_rms, feat_zcr, feat_crest, feat_shape);
        end
        if (fft_done) begin
            fft_cnt = fft_cnt + 1;
            $display("t=%0t [FFT  #%0d] fund_bin=%0d fund_mag=%0d dc=%0d spec_cent=%0d",
                $time, fft_cnt,
                fft_fund_bin, fft_fund_mag, fft_dc_mag, fft_spec_cent);
        end
        if (anom_flag) begin
            anom_ev = anom_ev + 1;
            $display("t=%0t [ANOM     ] sev=%0d mag=%0d zscore=%0d count=%0d",
                $time, anom_sev, anom_mag, anom_zscore, anom_count);
        end
        if (ml_fvec_ready) begin
            ml_cnt = ml_cnt + 1;
            $display("t=%0t [ML   #%0d] frame_count=%0d awaddr=0x%08X",
                $time, ml_cnt, ml_frame_count, m_axi_awaddr);
        end
    end

    // =========================================================================
    // wait_feat: pure-Verilog task to wait for N feat_valid pulses
    // =========================================================================
    task wait_feat;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                while (!feat_valid) @(posedge clk);
            end
        end
    endtask

    // =========================================================================
    // Main stimulus - 6 phases
    // =========================================================================
    initial begin
        // --- defaults ---
        rst_n            = 1'b0;
        ctrl_enable      = 1'b0;
        ctrl_soft_rst    = 1'b0;
        ctrl_filt_bypass = 1'b0;
        ctrl_feat_en     = 1'b0;
        ctrl_anom_en     = 1'b0;
        ctrl_dec_en      = 1'b0;
        ctrl_fft_en      = 1'b0;
        ctrl_ml_en       = 1'b0;
        ctrl_stim_en     = 1'b0;
        stim_mode        = 2'b01;
        stim_rate        = 16'd4;    // 1 sample every 4 clocks
        stim_amp         = 16'd1000;
        stim_freq        = 16'd512;
        win_size         = 5'd8;     // 8-sample window → fast feat_valid
        fft_size         = 2'b00;    // N=16
        threshold        = 16'd2000;
        hyst_lo          = 16'd400;
        crit_dwell       = 4'd3;
        ml_base_addr     = 32'h1000_0000;
        ml_norm_en       = 1'b0;

        // --- reset ---
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5)  @(posedge clk);

        // Enable everything via stim generator
        ctrl_stim_en = 1'b1;
        ctrl_enable  = 1'b1;
        ctrl_feat_en = 1'b1;
        ctrl_fft_en  = 1'b1;
        ctrl_anom_en = 1'b1;
        ctrl_dec_en  = 1'b1;
        ctrl_ml_en   = 1'b1;

        // ==============================================================
        // PHASE 1: Sine - normal amplitude, no anomaly
        // ==============================================================
        $display("\n=== PHASE 1: SINE (amp=1000, below threshold=2000) ===");
        stim_mode = 2'b01;
        stim_amp  = 16'd1000;
        wait_feat(4);
        repeat(5) @(posedge clk);

        // ==============================================================
        // PHASE 2: Sine + Spikes - spikes exceed threshold → anomaly
        // ==============================================================
        $display("\n=== PHASE 2: SINE+SPIKES (amp=4000, above threshold=2000) ===");
        stim_mode = 2'b10;
        stim_amp  = 16'd4000;
        wait_feat(4);
        repeat(5) @(posedge clk);

        // ==============================================================
        // PHASE 3: Ramp
        // ==============================================================
        $display("\n=== PHASE 3: RAMP ===");
        stim_mode = 2'b00;
        stim_amp  = 16'd1000;
        wait_feat(4);
        repeat(5) @(posedge clk);

        // ==============================================================
        // PHASE 4: Noise
        // ==============================================================
        $display("\n=== PHASE 4: RANDOM NOISE ===");
        stim_mode = 2'b11;
        stim_amp  = 16'd1000;
        wait_feat(4);
        repeat(5) @(posedge clk);

        // ==============================================================
        // PHASE 5: Filter bypass - raw signal goes straight to feat_ext
        // ==============================================================
        $display("\n=== PHASE 5: FILTER BYPASS ===");
        ctrl_filt_bypass = 1'b1;
        stim_mode = 2'b01;
        stim_amp  = 16'd800;
        wait_feat(4);
        repeat(5) @(posedge clk);
        ctrl_filt_bypass = 1'b0;

        // ==============================================================
        // PHASE 6: External AXI-Stream data (stim disabled)
        // s_axis_tdata/tvalid/tready are now the active path
        // ==============================================================
        $display("\n=== PHASE 6: EXTERNAL AXI-STREAM (ctrl_stim_en=0) ===");
        ctrl_stim_en = 1'b0;   // mux now selects s_axis_*
        // s_axis is being toggled by the always block above with a counter
        wait_feat(4);
        repeat(5) @(posedge clk);
        ctrl_stim_en = 1'b1;   // back to stim

        // ==============================================================
        // PHASE 7: Soft reset mid-run
        // ==============================================================
        $display("\n=== PHASE 7: SOFT RESET ===");
        ctrl_soft_rst = 1'b1;
        repeat(4) @(posedge clk);
        ctrl_soft_rst = 1'b0;
        $display("    Soft reset released.");
        stim_mode = 2'b01;
        stim_amp  = 16'd1000;
        wait_feat(4);
        repeat(5) @(posedge clk);

        // ==============================================================
        // Summary
        // ==============================================================
        $display("\n============ SIMULATION COMPLETE ============");
        $display("  Feature windows  : %0d", feat_cnt);
        $display("  FFT completions  : %0d", fft_cnt);
        $display("  Anomaly events   : %0d", anom_ev);
        $display("  ML DMA transfers : %0d", ml_cnt);
        $display("=============================================\n");
        $finish;
    end

    // =========================================================================
    // Watchdog - 50 ms
    // =========================================================================
    initial begin
        #50_000_000;
        $display("WATCHDOG: simulation exceeded 50 ms - check for stall.");
        $finish;
    end
endmodule
