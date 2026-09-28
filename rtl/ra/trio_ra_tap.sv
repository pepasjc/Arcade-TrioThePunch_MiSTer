// SPDX-License-Identifier: GPL-3.0-or-later
//
// RetroAchievements tap for the Trio The Punch MiSTer core.
//
// Turns the memory writes of the main HuC6280 (21-bit physical address) and
// of the sound 6502 into byte writes of the RA shadow (rtl/ra/ra_shadow.v),
// laid out exactly as FinalBurn Neo's d_actfancr.cpp "All Ram" block for
// triothep (MemIndex order; 8-bit CPUs, so mirror byte = CPU byte):
//
//   0x0000 Drv6280RAM  0x4000  main 0x1F0000-0x1F3FFF
//   0x4000 Drv6502RAM  0x0800  sound 0x0000-0x07FF
//   0x4800 DrvSprRAM   0x0800  main 0x120000-0x1207FF
//   0x5000 DrvPalRAM   0x0800  main 0x130000-0x1307FF
//   0x5800 DrvSprBuf   0x0800  copy of DrvSprRAM on a write to 0x110000
//   0x6000 soundlatch  0x0001  main 0x100000
//   0x6001 flipscreen  0x0001  (never written for triothep)
//   0x6002 DrvPf1RAM   0x2000  main 0x064000-0x0647FF
//   0x8002 DrvPf2RAM   0x2000  main 0x044000-0x045FFF
//   0xA002 DrvPf1Scr   0x0800  main 0x066000-0x0667FF
//   0xA802 DrvPf2Scr   0x0800  main 0x046000-0x0467FF
//   0xB002 DrvPfCtrl0  0x0020  main 0x060000-0x06001F
//   0xB022 DrvPfCtrl1  0x0020  main 0x040000-0x04001F
//
// The sprite buffer copy keeps its own 2 kB copy of the sprite RAM (the
// shadow has no spare read port) and replays it into the shadow in about
// 6k clocks after each buffer strobe, in the gaps between CPU writes.
// Priority: sound write (single-clock strobe) > main write (level, held for
// the whole CPU cycle) > buffer copy.

module trio_ra_tap (
    input             clk,
    // main HuC6280: level write strobe, physical address, data
    input             m_wr,
    input      [20:0] m_a,
    input       [7:0] m_d,
    input             spr_buffer,   // single-clock strobe: write to 0x110000
    // sound 6502 RAM write strobe (single clock)
    input             s_wr,
    input      [10:0] s_a,
    input       [7:0] s_d,
    // RA shadow write port
    output reg        ra_wr,
    output reg [14:0] ra_word,
    output reg [15:0] ra_din,
    output reg  [1:0] ra_be
);

reg  [15:0] m_off;
reg         m_hit;
always @(*) begin
    m_hit = 1'b1;
    m_off = 16'd0;
    casez (m_a)
        21'b1_1111_00??_????_????_????: m_off = 16'h0000 + {2'd0, m_a[13:0]};    // 0x1F0000-0x1F3FFF
        21'b1_0010_0000_0???_????_????: m_off = 16'h4800 + {5'd0, m_a[10:0]};    // 0x120000-0x1207FF
        21'b1_0011_0000_0???_????_????: m_off = 16'h5000 + {5'd0, m_a[10:0]};    // 0x130000-0x1307FF
        21'b1_0000_0000_0000_0000_0000: m_off = 16'h6000;                        // 0x100000
        21'b0_0110_0100_0???_????_????: m_off = 16'h6002 + {5'd0, m_a[10:0]};    // 0x064000-0x0647FF
        21'b0_0100_010?_????_????_????: m_off = 16'h8002 + {3'd0, m_a[12:0]};    // 0x044000-0x045FFF
        21'b0_0110_0110_0???_????_????: m_off = 16'hA002 + {5'd0, m_a[10:0]};    // 0x066000-0x0667FF
        21'b0_0100_0110_0???_????_????: m_off = 16'hA802 + {5'd0, m_a[10:0]};    // 0x046000-0x0467FF
        21'b0_0110_0000_0000_000?_????: m_off = 16'hB002 + {11'd0, m_a[4:0]};    // 0x060000-0x06001F
        21'b0_0100_0000_0000_000?_????: m_off = 16'hB022 + {11'd0, m_a[4:0]};    // 0x040000-0x04001F
        default: m_hit = 1'b0;
    endcase
end

// live copy of the sprite RAM for the buffer copy
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] spr_live [0:2047];
reg [7:0] spr_q;
reg [10:0] cp_a;
wire spr_hit = m_wr && m_a[20:11] == 10'b1_0010_0000_0;
always @(posedge clk) begin
    if (spr_hit) spr_live[m_a[10:0]] <= m_d;
    spr_q <= spr_live[cp_a];
end

// copy FSM: 0 idle, 1 address presented, 2 data valid (write when free)
reg [1:0] cp_st = 2'd0;
reg       cp_again = 1'b0;

task automatic put(input [15:0] off, input [7:0] d);
    begin
        ra_wr   <= 1'b1;
        ra_word <= off[15:1];
        ra_din  <= {d, d};
        ra_be   <= off[0] ? 2'b10 : 2'b01;
    end
endtask

always @(posedge clk) begin
    ra_wr <= 1'b0;
    if (spr_buffer) begin
        if (cp_st == 2'd0) begin cp_st <= 2'd1; cp_a <= 11'd0; end
        else cp_again <= 1'b1;
    end
    if (s_wr) begin
        put(16'h4000 + {5'd0, s_a}, s_d);
    end else if (m_wr && m_hit) begin
        put(m_off, m_d);
    end else if (cp_st == 2'd2) begin
        put(16'h5800 + {5'd0, cp_a}, spr_q);
        if (&cp_a) begin
            cp_st    <= cp_again ? 2'd1 : 2'd0;
            cp_again <= 1'b0;
        end else
            cp_st <= 2'd1;
        cp_a <= cp_a + 11'd1;
    end
    if (cp_st == 2'd1) cp_st <= 2'd2;
end

endmodule
