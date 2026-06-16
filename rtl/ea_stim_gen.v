// =============================================================================
// Module      : ea_stim_gen
// Description : Stimulus generator with four selectable output modes:
//                 2'b00 — Ramp
//                 2'b01 — Sine (CORDIC-free parabolic approximation)
//                 2'b10 — Sine + periodic spike injection
//                 2'b11 — LFSR pseudo-random noise
//               Output is presented on an AXI4-Stream master interface,
//               gated by a configurable sample-rate decimation counter.
// =============================================================================

module ea_stim_gen #(
    parameter integer DATA_W       = 16,
    parameter integer PHASE_W      = 16,
    parameter integer SPIKE_PERIOD = 256
)(
    // -------------------------------------------------------------------------
    // Clock and Reset
    // -------------------------------------------------------------------------
    input  wire clk_i,
    input  wire rst_ni,

    // -------------------------------------------------------------------------
    // Runtime Configuration
    // -------------------------------------------------------------------------
    input  wire        enable_i,
    input  wire [1:0]  mode_i,
    input  wire [15:0] stim_rate_i,    // Decimation reload value
    input  wire [15:0] stim_amp_i,     // Output amplitude
    input  wire [15:0] stim_freq_i,    // Phase increment per sample tick

    // -------------------------------------------------------------------------
    // AXI4-Stream Master Output
    // -------------------------------------------------------------------------
    output reg  [DATA_W-1:0] m_axis_tdata,
    output reg               m_axis_tvalid,
    input  wire              m_axis_tready
);

// =============================================================================
// Sample-Rate Decimation Counter
// =============================================================================

reg [15:0] dec_cnt;

wire sample_tick = (dec_cnt == 16'd0);

always @(posedge clk_i) begin
    if (!rst_ni || !enable_i)
        dec_cnt <= stim_rate_i;
    else
        dec_cnt <= sample_tick ? stim_rate_i : (dec_cnt - 1'b1);
end

// =============================================================================
// Phase Accumulator
// =============================================================================

reg [PHASE_W-1:0] phase_acc;

always @(posedge clk_i) begin
    if (!rst_ni)
        phase_acc <= {PHASE_W{1'b0}};
    else if (sample_tick && enable_i)
        phase_acc <= phase_acc + stim_freq_i;
end

// =============================================================================
// Ramp Generator
// =============================================================================

reg [DATA_W-1:0] ramp_reg;

always @(posedge clk_i) begin
    if (!rst_ni)
        ramp_reg <= {DATA_W{1'b0}};
    else if (sample_tick && enable_i)
        ramp_reg <= ramp_reg + 1'b1;
end

// =============================================================================
// Approximate Sine Generation (CORDIC-Free Parabolic Method)
// =============================================================================

wire [1:0]  quadrant  = phase_acc[PHASE_W-1 : PHASE_W-2];
wire [13:0] phase_lsb = phase_acc[PHASE_W-3 : 0];

// Signed value centred around zero
wire signed [14:0] xq     = {1'b0, phase_lsb} - 15'd8192;
wire signed [14:0] xq_abs = xq[14] ? (~xq + 1'b1) : xq;

// DSP-inferred parabola: y = x * (8192 - |x|)
(* use_dsp = "yes" *)
wire signed [28:0] y_para = xq * $signed({1'b0, (14'd8192 - xq_abs[13:0])});

// Fold into the correct quadrant
wire              invert   = quadrant[0];
wire signed [28:0] y_folded = invert ? (-y_para) : y_para;

// DSP-inferred amplitude scaling
(* use_dsp = "yes" *)
wire signed [44:0] y_scaled = y_folded * $signed({1'b0, stim_amp_i});

wire signed [DATA_W-1:0] sine_out = y_scaled[43 : 43-(DATA_W-1)];

// =============================================================================
// Spike Injection Logic
// =============================================================================

reg [$clog2(SPIKE_PERIOD)-1:0] spike_cnt;
reg                             spike_now;

always @(posedge clk_i) begin
    if (!rst_ni) begin
        spike_cnt <= {$clog2(SPIKE_PERIOD){1'b0}};
        spike_now <= 1'b0;
    end
    else if (sample_tick && enable_i) begin
        spike_now <= 1'b0;

        if (spike_cnt == SPIKE_PERIOD - 1) begin
            spike_cnt <= {$clog2(SPIKE_PERIOD){1'b0}};
            spike_now <= 1'b1;
        end
        else begin
            spike_cnt <= spike_cnt + 1'b1;
        end
    end
end

// Saturated spike amplitude — clamp to positive full-scale if overflow
wire signed [DATA_W-1:0] spike_val =
    (stim_amp_i[DATA_W-3:0] >= {(DATA_W-2){1'b1}})
        ? {1'b0, {(DATA_W-1){1'b1}}}           // Positive full-scale
        : {1'b0, stim_amp_i[DATA_W-3:0], 2'b00};

// =============================================================================
// LFSR Pseudo-Random Noise Generator (17-bit Galois LFSR)
// =============================================================================

reg [16:0] lfsr;

always @(posedge clk_i) begin
    if (!rst_ni)
        lfsr <= 17'h1FFFF;                      // Non-zero seed
    else if (sample_tick && enable_i)
        lfsr <= {lfsr[15:0], lfsr[16] ^ lfsr[13]};
end

wire signed [DATA_W-1:0] noise_sample = $signed(lfsr[DATA_W-1:0]) >>> 2;

// =============================================================================
// Output Waveform Select Mux
// =============================================================================

reg signed [DATA_W-1:0] sample_d;

always @(*) begin
    case (mode_i)
        2'b00   : sample_d = $signed({1'b0, ramp_reg});        // Ramp
        2'b01   : sample_d = sine_out;                         // Sine
        2'b10   : sample_d = spike_now ? spike_val : sine_out; // Sine + spike
        2'b11   : sample_d = noise_sample;                     // LFSR noise
        default : sample_d = {DATA_W{1'b0}};
    endcase
end

// =============================================================================
// AXI4-Stream Output Register
// =============================================================================

always @(posedge clk_i) begin
    if (!rst_ni) begin
        m_axis_tdata  <= {DATA_W{1'b0}};
        m_axis_tvalid <= 1'b0;
    end
    else begin
        if (sample_tick && enable_i) begin
            m_axis_tdata  <= sample_d;
            m_axis_tvalid <= 1'b1;
        end
        else if (m_axis_tready) begin
            m_axis_tvalid <= 1'b0;
        end
    end
end

// =============================================================================
endmodule
// =============================================================================
