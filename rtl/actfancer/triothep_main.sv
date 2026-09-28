// SPDX-License-Identifier: GPL-3.0-or-later
// Trio The Punch — main CPU subsystem (HuC6280)
//
// MAME reference: dataeast/actfancr.cpp::triothep_state::prg_map (lines 175-192)
//
//   0x000000-0x03FFFF  ROM 256KB
//   0x040000-0x040007  PF1 BAC06 control0
//   0x040010-0x04001F  PF1 BAC06 control1 (8bit_swap)
//   0x044000-0x045FFF  PF1 VRAM           (R/W, 8bit_swap)  8KB region
//   0x046400-0x0467FF  PF1 rowscroll      (R/W, 8bit_swap)
//   0x060000-0x060007  PF0 BAC06 control0
//   0x060010-0x06001F  PF0 BAC06 control1 (8bit_swap)
//   0x064000-0x0647FF  PF0 VRAM           (R/W, 8bit_swap)  2KB
//   0x066400-0x0667FF  PF0 rowscroll      (R/W, 8bit_swap)
//   0x100000           soundlatch (W)
//   0x110000-0x110001  buffer_spriteram_w
//   0x120000-0x1207FF  Spriteram (2KB)
//   0x130000-0x1305FF  Palette
//   0x140000-0x140001  SYSTEM (nopr in MAME — VBL via SYSTEM port read di control_r)
//   0x1F0000-0x1F3FFF  Main RAM 16KB
//
// Inputs (P1/P2/DSW/SYSTEM) via HuC6280 K-port:
//   - O[7:0] (CPU output) seleziona quale input via control_select_w
//   - K[7:0] (CPU input)  ritorna value secondo control_r:
//       0 = P1, 1 = P2, 2 = DSW1, 3 = DSW2, 4 = SYSTEM (VBL+coin)
//
// VBL → /IRQ1 of H6280 (HOLD_LINE) — uguale ActFancer.

module triothep_main
(
    input              clk,           // 21.477 MHz master (in realtà 96 MHz)
    input              ce_h6280,      // CPU clock enable (~7.16 MHz)
    input              paused_safe,   // 1=ferma HUC6280 (RDY=0), gia` sync VBlank dal top
    input              rst_n,

    // From video
    input              vbl,           // 1 = vblank active

    // Inputs
    input        [7:0] p1,
    input        [7:0] p2,
    input        [7:0] coin,           // {x, x, x, x, x, service, coin2, coin1} active-low
    input        [7:0] dsw1,
    input        [7:0] dsw2,

    // ROM read (H6280 program ROM, 256KB @ SDRAM 0x000000)
    output      [17:0] rom_addr,
    output reg         rom_cs,
    input        [7:0] rom_data,
    input              rom_ok,

    // PF0/PF1 BAC06 control busses (write strobes only)
    output             pf0_mode_cs,
    output             pf0_vram_cs,
    output             pf0_rsc_cs,    // PF0 rowscroll (NUOVO vs ActFancer)
    output             pf1_mode_cs,
    output             pf1_vram_cs,
    output             pf1_rsc_cs,    // PF1 rowscroll (NUOVO)
    output      [12:1] pf_addr,
    output       [7:0] pf_dout,
    output             pf_we,
    output             pf_a0,         // byte select inside 16-bit word
    input        [7:0] pf0_din,
    input        [7:0] pf1_din,

    // Spriteram (2KB) shared with sprite engine
    output      [10:0] spr_addr,
    output       [7:0] spr_dout,
    output             spr_we,
    output             spr_cs,
    input        [7:0] spr_din,
    output             spr_buffer,    // pulse on 0x110000 write

    // Palette (1536 bytes = 768 entries × 2 bytes, xBGR_444)
    output      [10:0] pal_addr,
    output       [7:0] pal_dout,
    output             pal_we,
    input        [7:0] pal_din,
    output             pal_cs,

    // Sound latch out
    output       [7:0] snd_latch,
    output             snd_latch_we,

    // RetroAchievements tap: CPU writes (level strobe, physical address)
    output             ra_wr,
    output      [20:0] ra_a,
    output       [7:0] ra_d,

    // RetroAchievements: 64-bit read port of the main RAM (qword index,
    // byte 8n in bits 7:0, data one ra_clk later)
    input              ra_clk,
    input       [10:0] ra_rd_addr,
    output      [63:0] ra_rd_q
);

// ---------------------------------------------------------------
// HUC6280 instance
// ---------------------------------------------------------------
wire [20:0] cpu_a;
wire [7:0]  cpu_do, cpu_di;
wire        cpu_wrn, cpu_rdn, cpu_ce, cpu_sx;
wire [7:0]  cpu_o, cpu_k;

reg  [7:0]  din_mux;
initial     din_mux = 8'h00;
wire        wait_n;

// ---------------------------------------------------------------
// CS decode (combinational on cpu_a) — triothep memory map
// ---------------------------------------------------------------
// ROM 256KB: cpu_a[20]=0 AND cpu_a[19:18]=00 (banchi $00-$1F)
wire cs_rom    = cpu_a[20] == 1'b0 && cpu_a[19:18] == 2'b00;

// PF1 region $040000-$047FFF (banco $20-$23)
wire cs_pf1_reg = cpu_a[20] == 1'b0 && cpu_a[19:16] == 4'h4;
//   ctrl: $040000-$04001F (cpu_a[15:14]=00, cpu_a[13:5]=0)
wire cs_pf1_mode = cs_pf1_reg && cpu_a[15:14] == 2'b00 && cpu_a[13:5] == 9'b0;
//   VRAM: $044000-$045FFF  (cpu_a[15:13]=010)
wire cs_pf1_vram = cs_pf1_reg && cpu_a[15:13] == 3'b010;
//   rowscroll: $046400-$0467FF (cpu_a[15:11]=01100, cpu_a[10]=1) → 1KB
wire cs_pf1_rsc  = cs_pf1_reg && cpu_a[15:11] == 5'b01100 && cpu_a[10] == 1'b1;

// PF0 region $060000-$067FFF (banco $30-$33)
wire cs_pf0_reg = cpu_a[20] == 1'b0 && cpu_a[19:16] == 4'h6;
wire cs_pf0_mode = cs_pf0_reg && cpu_a[15:14] == 2'b00 && cpu_a[13:5] == 9'b0;
//   VRAM: $064000-$0647FF (cpu_a[15:13]=010, [12:11]=00) → 2KB
wire cs_pf0_vram = cs_pf0_reg && cpu_a[15:13] == 3'b010 && cpu_a[12:11] == 2'b00;
//   rowscroll: $066400-$0667FF
wire cs_pf0_rsc  = cs_pf0_reg && cpu_a[15:11] == 5'b01100 && cpu_a[10] == 1'b1;

// Devices A20=1
wire cs_slatch = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h0 && cpu_a[15:5] == 11'd0; // $100000
wire cs_sbuf   = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h1 && cpu_a[15:5] == 11'd0; // $110000
wire cs_spr    = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h2 && cpu_a[15:11] == 5'h00; // $120000-$1207FF
wire cs_pal    = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h3 && cpu_a[15:11] == 5'h00; // $130000-$1305FF
wire cs_sys    = cpu_a[20] == 1'b1 && cpu_a[19:16] == 4'h4;                          // $140000 (nopr MAME)
// Main RAM $1F0000-$1F3FFF → A20=1, A19:14=6'b111100
wire cs_ram    = cpu_a[20] == 1'b1 && cpu_a[19:14] == 6'b111100;

// ---------------------------------------------------------------
// Main RAM 16KB (BRAM read-always)
// ---------------------------------------------------------------
// RetroAchievements fork: explicit dual-port M10K (rtl/ra/ra_ram8_rd64.sv)
// so a second, read-only 64-bit port can serve the RA RAM mirror. Port A
// keeps the original timing (registered address, data one clock later).
wire [7:0] ram_q;
wire ram_we = cs_ram && ~cpu_wrn;
ra_ram8_rd64 #(.WIDTHAD(14)) main_ram (
    .clock    (clk),
    .we       (ram_we),
    .address  (cpu_a[13:0]),
    .data     (cpu_do),
    .q        (ram_q),
    .clock_b  (ra_clk),
    .address_b(ra_rd_addr),
    .q_b      (ra_rd_q)
);

// ---------------------------------------------------------------
// K-port input mux (Trio-specific): cpu_o seleziona quale input restituire.
// HuC6280 mantiene `O` registrato internamente al write IOP, quindi cpu_o
// è già stabile. Mux direttamente su cpu_o (no registro extra).
// ---------------------------------------------------------------
// SYSTEM (VBL + coin) — MAME PORT_START("SYSTEM"):
//   bit 0=COIN1, bit 1=COIN2, bit 2=SERVICE1 (tutti active-low),
//   bits 3-6 = UNKNOWN active-low (default high), bit 7=VBL active-high.
wire [7:0] sys_q = { vbl, 5'b11111, coin[1:0] };

// K port output mux (control_r case mapping)
assign cpu_k = (cpu_o == 8'd0) ? p1   :
               (cpu_o == 8'd1) ? p2   :
               (cpu_o == 8'd2) ? dsw1 :
               (cpu_o == 8'd3) ? dsw2 :
               (cpu_o == 8'd4) ? sys_q:
                                 8'hFF;

// ---------------------------------------------------------------
// DI mux
// ---------------------------------------------------------------
always @* begin
    din_mux = 8'hFF;
    casez ({cs_rom, cs_ram, cs_pf0_vram, cs_pf1_vram, cs_spr, cs_pal})
        6'b1?????: din_mux = rom_data;
        6'b01????: din_mux = ram_q;
        6'b001???: din_mux = pf0_din;
        6'b0001??: din_mux = pf1_din;
        6'b00001?: din_mux = spr_din;
        6'b000001: din_mux = pal_din;
        default:   din_mux = 8'hFF;
    endcase
end

assign rom_addr = cpu_a[17:0];
always @(posedge clk) if (cpu_sx) rom_cs <= cs_rom;
assign wait_n = ~cs_rom | rom_ok;
assign cpu_di = din_mux;

// ---------------------------------------------------------------
// PF bus fanout
// ---------------------------------------------------------------
assign pf0_mode_cs = cs_pf0_mode;
assign pf0_vram_cs = cs_pf0_vram;
assign pf0_rsc_cs  = cs_pf0_rsc;
assign pf1_mode_cs = cs_pf1_mode;
assign pf1_vram_cs = cs_pf1_vram;
assign pf1_rsc_cs  = cs_pf1_rsc;
assign pf_addr     = cpu_a[12:1];
assign pf_dout     = cpu_do;
assign pf_we       = ~cpu_wrn & cpu_ce;
assign pf_a0       = cpu_a[0];

// Spriteram
assign spr_addr    = cpu_a[10:0];
assign spr_dout    = cpu_do;
assign spr_we      = cs_spr & ~cpu_wrn & cpu_ce;
assign spr_cs      = cs_spr;
assign spr_buffer  = cs_sbuf & ~cpu_wrn & cpu_ce;

// Palette
assign pal_addr    = cpu_a[10:0];
assign pal_dout    = cpu_do;
assign pal_we      = cs_pal & ~cpu_wrn & cpu_ce;
assign pal_cs      = cs_pal;

// Sound latch
reg [7:0] snd_latch_r;
wire snd_latch_we_w = cs_slatch & ~cpu_wrn & cpu_ce;
always @(posedge clk) begin
    if (snd_latch_we_w) snd_latch_r <= cpu_do;
end
assign snd_latch     = snd_latch_r;

assign ra_wr = ~cpu_wrn;
assign ra_a  = cpu_a;
assign ra_d  = cpu_do;
assign snd_latch_we  = snd_latch_we_w;

// VBL → IRQ1 (HOLD_LINE equivalente)
// MAME: screen.screen_vblank().set_inputline(m_maincpu, 0, HOLD_LINE)
//
// PROBLEMA: il mio precedente `irq1_n = ~vbl` teneva IRQ asserito per tutta la
// durata di VBL (~30 scanline). Dopo che l'ISR fa RTI (FLAG_I=0), IRQ1_N era
// ancora 0 e GOT_INT=(~IRQ1_N & ~FLAG_I) ri-trigger immediato → ISR rientrava
// 5-10 volte per frame → timer countdown a 0 istantaneo, selezione personaggio
// scrolla via, gameplay accelerato.
//
// FIX: edge-detect su VBL, IRQ1_N asserito solo per 8 cicli di CPU (cpu_ce),
// abbastanza perché HUC6280 lo campioni all'istruzione boundary ma molto meno
// della durata VBL → niente rientro post-RTI.
reg vbl_q;
reg [3:0] irq1_cnt;
always @(posedge clk) begin
    if (!rst_n) begin
        vbl_q    <= 1'b0;
        irq1_cnt <= 4'd0;
    end else begin
        vbl_q <= vbl;
        if (vbl && !vbl_q)               irq1_cnt <= 4'd15;       // rising edge VBL
        else if (cpu_ce && irq1_cnt != 0) irq1_cnt <= irq1_cnt - 4'd1;
    end
end
wire irq1_n = (irq1_cnt == 4'd0);

HUC6280 u_huc (
    .CLK        (clk),
    .RST_N      (rst_n),
    .WAIT_N     (wait_n),
    .SX         (cpu_sx),

    .A          (cpu_a),
    .DI         (cpu_di),
    .DO         (cpu_do),
    .WR_N       (cpu_wrn),
    .RD_N       (cpu_rdn),

    .RDY        (~paused_safe),
    .NMI_N      (1'b1),
    .IRQ1_N     (irq1_n),
    .IRQ2_N     (1'b1),

    .CE         (cpu_ce),
    .CEK_N      (),
    .CE7_N      (),
    .CER_N      (),
    .PRE_RD     (),
    .PRE_WR     (),
    .HSM        (),
    .O          (cpu_o),       // K-port output (control_select_w)
    .K          (cpu_k),       // K-port input  (control_r)
    .VDCNUM     (1'b0),
    .AUD_LDATA  (),
    .AUD_RDATA  ()
);

endmodule
