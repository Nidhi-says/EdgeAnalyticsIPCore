// ============================================================================
// File        : ea_fft_engine.v
// Project     : Edge Analytics IP - PYNQ-Z2
//
// Description : Simplified synthesizable FFT engine.
//               FIXED:
//               1. fft_n registered (not combinational) to avoid stale read
//                  during wr_ptr comparison.
//               2. FSM counts samples directly; transitions on fill count
//                  reaching fft_n so done_o fires reliably.
//               3. fund_mag_o / spec_cent_o reset at start of each PROCESS
//                  frame so comparisons are always valid.
// ============================================================================

module ea_fft_engine #(
    parameter DATA_W      = 16,
    parameter FEAT_W      = 32,
    parameter FFT_MAX_LOG = 7
)(
    input  wire                     clk_i,
    input  wire                     rst_ni,
    input  wire                     enable_i,

    input  wire signed [DATA_W-1:0] din_i,
    input  wire                     din_valid_i,

    input  wire [1:0]               fft_size_i,

    output reg  [FFT_MAX_LOG-1:0]   fund_bin_o,
    output reg  [FEAT_W-1:0]        fund_mag_o,
    output reg  [FEAT_W-1:0]        dc_mag_o,
    output reg  [FEAT_W-1:0]        spec_cent_o,

    output reg                      done_o
);

    // =========================================================================
    // FIX 1: Register fft_n so it is stable throughout a frame.
    //        Only update when the FSM is IDLE and not accumulating.
    // =========================================================================
    reg [FFT_MAX_LOG-1:0] fft_n;
    reg [FFT_MAX_LOG-1:0] fft_n_next;

    always @(*) begin
        case (fft_size_i)
            2'b00:   fft_n_next = 16;
            2'b01:   fft_n_next = 32;
            2'b10:   fft_n_next = 64;
            default: fft_n_next = 128;
        endcase
    end

    // =========================================================================
    // Sample buffer
    // =========================================================================
    reg signed [DATA_W-1:0] sample_mem [0:127];
    reg [FFT_MAX_LOG-1:0]   wr_ptr;

    // FIX 2: Explicit fill counter so IDLE→LOAD is driven by a registered,
    //        stable count - no combinational fft_n risk.
    reg [FFT_MAX_LOG-1:0]   fill_cnt;   // samples accepted this frame

    // =========================================================================
    // FFT work arrays
    // =========================================================================
    reg signed [DATA_W:0] xr [0:127];
    reg signed [DATA_W:0] xi [0:127];
    reg [FEAT_W-1:0]      mag [0:63];

    integer i;

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam IDLE    = 2'd0;
    localparam LOAD    = 2'd1;
    localparam PROCESS = 2'd2;
    localparam DONE    = 2'd3;

    reg [1:0]             state;
    reg [FFT_MAX_LOG-1:0] proc_ptr;

    // =========================================================================
    // Input buffering (always running when enabled)
    // =========================================================================
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            wr_ptr   <= 0;
            fill_cnt <= 0;
        end
        else if (enable_i && din_valid_i && (state == IDLE)) begin
            sample_mem[wr_ptr] <= din_i;

            if (wr_ptr == fft_n - 1'b1)
                wr_ptr <= 0;
            else
                wr_ptr <= wr_ptr + 1'b1;

            fill_cnt <= fill_cnt + 1'b1;
        end
        // Reset fill counter when we leave IDLE (frame consumed)
        else if (state != IDLE) begin
            fill_cnt <= 0;
            wr_ptr   <= 0;
        end
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            state      <= IDLE;
            done_o     <= 0;
            proc_ptr   <= 0;
            fft_n      <= 16;

            fund_bin_o  <= 0;
            fund_mag_o  <= 0;
            dc_mag_o    <= 0;
            spec_cent_o <= 0;

            for (i = 0; i < 128; i = i + 1) begin
                xr[i] <= 0;
                xi[i] <= 0;
            end
            for (i = 0; i < 64; i = i + 1)
                mag[i] <= 0;
        end
        else begin
            done_o <= 0;

            case (state)

                // =============================================================
                // IDLE - wait until fill_cnt reaches fft_n
                // FIX 2: comparison uses registered fill_cnt (stable) and
                //        registered fft_n (stable).
                // =============================================================
                IDLE: begin
                    // Latch fft_n while idle so it is stable for the frame
                    fft_n <= fft_n_next;

                    // FIX 2: transition when we have collected exactly fft_n samples
                    if (enable_i && (fill_cnt == fft_n)) begin
                        proc_ptr <= 0;
                        state    <= LOAD;
                    end
                end

                // =============================================================
                // LOAD - copy sample_mem → xr, clear xi
                // =============================================================
                LOAD: begin
                    xr[proc_ptr] <= {{1{sample_mem[proc_ptr][DATA_W-1]}},
                                      sample_mem[proc_ptr]};
                    xi[proc_ptr] <= 0;

                    if (proc_ptr == fft_n - 1'b1) begin
                        proc_ptr <= 0;

                        // FIX 3: reset spectral features at start of each frame
                        fund_mag_o  <= 0;
                        fund_bin_o  <= 0;
                        dc_mag_o    <= 0;
                        spec_cent_o <= 0;

                        state <= PROCESS;
                    end
                    else
                        proc_ptr <= proc_ptr + 1'b1;
                end

                // =============================================================
                // PROCESS - simplified radix-2 butterfly & magnitude
                // FIX 3: fund_mag_o starts at 0 (reset in LOAD) so the
                //        > comparison always works correctly.
                // =============================================================
                PROCESS: begin
                    if (proc_ptr < (fft_n >> 1)) begin
                        // Butterfly (magnitude only, no twiddle approx)
                        xr[proc_ptr] <= xr[proc_ptr] + xr[proc_ptr + (fft_n>>1)];
                        xi[proc_ptr] <= xi[proc_ptr] + xi[proc_ptr + (fft_n>>1)];

                        // Manhattan magnitude |Re|+|Im|
                        mag[proc_ptr] <=
                            (xr[proc_ptr][DATA_W] ?
                                (~xr[proc_ptr] + 1'b1) : xr[proc_ptr]) +
                            (xi[proc_ptr][DATA_W] ?
                                (~xi[proc_ptr] + 1'b1) : xi[proc_ptr]);

                        // DC bin
                        if (proc_ptr == 0)
                            dc_mag_o <= mag[proc_ptr];

                        // Peak detection (valid because fund_mag_o reset to 0)
                        if (mag[proc_ptr] > fund_mag_o) begin
                            fund_mag_o <= mag[proc_ptr];
                            fund_bin_o <= proc_ptr;
                        end

                        // Spectral centroid accumulation
                        spec_cent_o <= spec_cent_o +
                                       (mag[proc_ptr] * {{(FEAT_W-FFT_MAX_LOG){1'b0}},
                                                         proc_ptr});
                    end

                    if (proc_ptr == (fft_n >> 1) - 1'b1)
                        state <= DONE;
                    else
                        proc_ptr <= proc_ptr + 1'b1;
                end

                // =============================================================
                // DONE - assert done for one cycle, return to IDLE
                // =============================================================
                DONE: begin
                    done_o <= 1'b1;
                    state  <= IDLE;
                end

            endcase
        end
    end

endmodule
