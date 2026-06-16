// =============================================================================
// Module      : ea_ma_filter
// Description : Configurable-length recursive moving-average (MA) filter.
//               Uses a circular buffer and a running accumulator for O(1)
//               per-sample updates. Window length must be a power of two;
//               division is implemented as an arithmetic right-shift.
//
//               Pipeline stages:
//                 Stage 0 — Address decode, circular buffer write
//                 Stage 1 — Recursive accumulator update (add new, sub old)
//                 Stage 2 — Arithmetic shift (divide by N) → output
//
//               Runtime reconfiguration (win_size_i / bypass_i) is detected
//               combinatorially and triggers a safe flush of all state.
// =============================================================================

module ea_ma_filter #(
    parameter integer DATA_W      = 16,
    parameter integer MAX_WIN_LOG = 5
)(
    // -------------------------------------------------------------------------
    // Clock and Reset
    // -------------------------------------------------------------------------
    input  wire clk_i,
    input  wire rst_ni,

    // -------------------------------------------------------------------------
    // Input Stream
    // -------------------------------------------------------------------------
    input  wire signed [DATA_W-1:0] din_i,
    input  wire                     din_valid_i,
    output reg                      rd_en_o,        // Back-pressure / consume strobe

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------
    input  wire [MAX_WIN_LOG-1:0] win_size_i,       // Window length (power of two)
    input  wire                   bypass_i,          // Pass-through mode

    // -------------------------------------------------------------------------
    // Output Stream
    // -------------------------------------------------------------------------
    output reg signed [DATA_W-1:0] dout_o,
    output reg                     dout_valid_o
);

// =============================================================================
// Derived Constants
// =============================================================================

localparam integer MAX_WIN = (1 << MAX_WIN_LOG);
localparam integer SUM_W   = DATA_W + MAX_WIN_LOG;

// =============================================================================
// Circular Buffer  (distributed RAM)
// =============================================================================

(* ram_style = "distributed" *)
reg signed [DATA_W-1:0] circ_buf [0:MAX_WIN-1];

// =============================================================================
// Function : log2_pow2
// Description : Returns the log2 of a power-of-two value by scanning for the
//               set bit.  Used to derive the arithmetic shift amount.
// =============================================================================

function [MAX_WIN_LOG-1:0] log2_pow2;
    input [MAX_WIN_LOG-1:0] n;
    integer i;
    begin
        log2_pow2 = {MAX_WIN_LOG{1'b0}};
        for (i = 0; i < MAX_WIN_LOG; i = i + 1) begin
            if (n[i])
                log2_pow2 = i[MAX_WIN_LOG-1:0];
        end
    end
endfunction

// =============================================================================
// Configuration Shadow Registers
// =============================================================================

reg [MAX_WIN_LOG-1:0] win_q;
reg                   bypass_q;

wire cfg_changed = (win_size_i != win_q) | (bypass_i != bypass_q);

// =============================================================================
// Main State Registers
// =============================================================================

reg signed [SUM_W-1:0] accum;          // Running accumulator
reg [MAX_WIN_LOG-1:0]  wr_ptr;         // Circular buffer write pointer
reg [MAX_WIN_LOG-1:0]  fill_cnt;       // Samples written since last flush
reg                    buf_primed;      // High once >= win_q samples have arrived

// =============================================================================
// Stage 1 Pipeline Registers
// =============================================================================

reg signed [DATA_W-1:0] s1_x_new;     // New sample captured from din_i
reg [MAX_WIN_LOG-1:0]   s1_rd_addr;   // Address of oldest sample to evict
reg signed [SUM_W-1:0]  s1_accum;     // Accumulator snapshot for this stage
reg                     s1_primed;     // Primed flag passed through
reg [MAX_WIN_LOG-1:0]   s1_shift;     // Shift amount (log2 of window)
reg                     s1_valid;

// =============================================================================
// Stage 2 Pipeline Registers
// =============================================================================

reg signed [SUM_W-1:0] s2_accum_new;  // Updated accumulator from stage 1
reg [MAX_WIN_LOG-1:0]  s2_shift;      // Shift amount passed through
reg                    s2_valid;

// =============================================================================
// Combinatorial Signals
// =============================================================================

// Oldest sample read address (wraps naturally via truncation)
wire [MAX_WIN_LOG-1:0]   old_addr  = wr_ptr - win_q;

// Oldest sample value (registered read from circular buffer)
wire signed [DATA_W-1:0] x_oldest  = circ_buf[s1_rd_addr];

// Shift amount derived from the current window size
wire [MAX_WIN_LOG-1:0]   shift_amt = log2_pow2(win_q);

// =============================================================================
// Main Sequential Logic
// =============================================================================

integer              ci;
reg signed [SUM_W-1:0] new_sum;
reg signed [SUM_W-1:0] x_new_ext;
reg signed [SUM_W-1:0] x_old_ext;

always @(posedge clk_i) begin

    // -------------------------------------------------------------------------
    // Reset
    // -------------------------------------------------------------------------
    if (!rst_ni) begin

        accum      <= {SUM_W{1'b0}};
        wr_ptr     <= {MAX_WIN_LOG{1'b0}};
        fill_cnt   <= {MAX_WIN_LOG{1'b0}};
        buf_primed <= 1'b0;

        win_q      <= 5'd8;
        bypass_q   <= 1'b0;

        s1_valid   <= 1'b0;
        s2_valid   <= 1'b0;

        rd_en_o      <= 1'b0;
        dout_o       <= {DATA_W{1'b0}};
        dout_valid_o <= 1'b0;

        for (ci = 0; ci < MAX_WIN; ci = ci + 1)
            circ_buf[ci] <= {DATA_W{1'b0}};

    end

    // -------------------------------------------------------------------------
    // Runtime Reconfiguration — flush all pipeline state
    // -------------------------------------------------------------------------
    else if (cfg_changed) begin

        win_q    <= win_size_i;
        bypass_q <= bypass_i;

        accum      <= {SUM_W{1'b0}};
        wr_ptr     <= {MAX_WIN_LOG{1'b0}};
        fill_cnt   <= {MAX_WIN_LOG{1'b0}};
        buf_primed <= 1'b0;

        s1_valid     <= 1'b0;
        s2_valid     <= 1'b0;
        dout_valid_o <= 1'b0;

        for (ci = 0; ci < MAX_WIN; ci = ci + 1)
            circ_buf[ci] <= {DATA_W{1'b0}};

    end

    // -------------------------------------------------------------------------
    // Normal Operation
    // -------------------------------------------------------------------------
    else begin

        // =====================================================================
        // Stage 0 : Circular Buffer Write + Pipeline Launch
        // =====================================================================
        rd_en_o  <= din_valid_i;
        s1_valid <= 1'b0;

        if (din_valid_i) begin

            // Write new sample into circular buffer
            circ_buf[wr_ptr] <= din_i;

            // Latch stage-1 operands
            s1_x_new   <= din_i;
            s1_rd_addr <= old_addr;
            s1_accum   <= accum;
            s1_primed  <= buf_primed;
            s1_shift   <= shift_amt;
            s1_valid   <= 1'b1;

            wr_ptr <= wr_ptr + 1'b1;

            // Track how many samples have been written since flush
            if (!buf_primed) begin
                if (fill_cnt == (win_q - 1'b1))
                    buf_primed <= 1'b1;
                fill_cnt <= fill_cnt + 1'b1;
            end

        end

        // =====================================================================
        // Stage 1 : Recursive Accumulator Update
        // =====================================================================
        s2_valid <= 1'b0;

        if (s1_valid) begin

            // Sign-extend both operands to SUM_W bits
            x_new_ext = {{(SUM_W-DATA_W){s1_x_new[DATA_W-1]}}, s1_x_new};
            x_old_ext = {{(SUM_W-DATA_W){x_oldest[DATA_W-1]}},  x_oldest};

            // Recursive MA: add new sample, subtract oldest once primed
            if (s1_primed)
                new_sum = s1_accum + x_new_ext - x_old_ext;
            else
                new_sum = s1_accum + x_new_ext;

            accum        <= new_sum;
            s2_accum_new <= new_sum;
            s2_shift     <= s1_shift;
            s2_valid     <= s1_primed;

        end

        // =====================================================================
        // Stage 2 : Arithmetic Shift → Output (or Bypass)
        // =====================================================================
        dout_valid_o <= 1'b0;

        if (bypass_q) begin
            dout_o       <= din_i;
            dout_valid_o <= din_valid_i;
        end
        else if (s2_valid) begin
            dout_o       <= ($signed(s2_accum_new) >>> s2_shift);
            dout_valid_o <= 1'b1;
        end

    end
end

// =============================================================================
endmodule
// =============================================================================
