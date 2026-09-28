/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 8-bit RAM plus a second, read-only port 64 bits wide, for the
 * RetroAchievements RAM mirror (ra_mirror_gather.v). The 8-bit sibling of
 * ra_ram16_rd64.sv (from the Taito F2 MiSTer core's RA fork).
 *
 * Port A: 8-bit read/write, registered address, data one clock later.
 * Port B: word n holds port A bytes 8n..8n+7, byte 8n in bits 7:0
 * (altsyncram mixed-width order), i.e. byte for byte as the RA mirror of an
 * 8-bit CPU's RAM wants it. Registered address, data one clock later, on its
 * own clock. Same M10K bits as a single-port 8-bit RAM of this size.
 * Contents power up as zero.
 */
module ra_ram8_rd64 #(
    parameter WIDTHAD = 13          // port A byte address width
) (
    input  wire               clock,
    input  wire               we,
    input  wire [WIDTHAD-1:0] address,
    input  wire         [7:0] data,
    output wire         [7:0] q,

    input  wire               clock_b,
    input  wire [WIDTHAD-4:0] address_b,
    output wire        [63:0] q_b
);

altsyncram altsyncram_component (
    .address_a      (address),
    .clock0         (clock),
    .data_a         (data),
    .wren_a         (we),
    .byteena_a      (1'b1),
    .q_a            (q),
    .address_b      (address_b),
    .clock1         (clock_b),
    .q_b            (q_b),
    .aclr0          (1'b0),
    .aclr1          (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .byteena_b      (1'b1),
    .clocken0       (1'b1),
    .clocken1       (1'b1),
    .clocken2       (1'b1),
    .clocken3       (1'b1),
    .data_b         (64'd0),
    .eccstatus      (),
    .rden_a         (1'b1),
    .rden_b         (1'b1),
    .wren_b         (1'b0));
defparam
    altsyncram_component.address_reg_b = "CLOCK1",
    altsyncram_component.clock_enable_input_a = "BYPASS",
    altsyncram_component.clock_enable_input_b = "BYPASS",
    altsyncram_component.clock_enable_output_a = "BYPASS",
    altsyncram_component.clock_enable_output_b = "BYPASS",
    altsyncram_component.indata_reg_b = "CLOCK1",
    altsyncram_component.intended_device_family = "Cyclone V",
    altsyncram_component.lpm_type = "altsyncram",
    altsyncram_component.numwords_a = 2**WIDTHAD,
    altsyncram_component.numwords_b = 2**(WIDTHAD-3),
    altsyncram_component.operation_mode = "BIDIR_DUAL_PORT",
    altsyncram_component.outdata_aclr_a = "NONE",
    altsyncram_component.outdata_aclr_b = "NONE",
    altsyncram_component.outdata_reg_a = "UNREGISTERED",
    altsyncram_component.outdata_reg_b = "UNREGISTERED",
    altsyncram_component.power_up_uninitialized = "FALSE",
    altsyncram_component.ram_block_type = "M10K",
    altsyncram_component.read_during_write_mode_mixed_ports = "DONT_CARE",
    altsyncram_component.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    altsyncram_component.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    altsyncram_component.widthad_a = WIDTHAD,
    altsyncram_component.widthad_b = WIDTHAD-3,
    altsyncram_component.width_a = 8,
    altsyncram_component.width_b = 64,
    altsyncram_component.width_byteena_a = 1,
    altsyncram_component.width_byteena_b = 1,
    altsyncram_component.wrcontrol_wraddress_reg_b = "CLOCK1";

endmodule
