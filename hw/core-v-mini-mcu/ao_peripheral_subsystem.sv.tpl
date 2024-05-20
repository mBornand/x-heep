// Copyright 2022 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module ao_peripheral_subsystem
  import obi_pkg::*;
  import reg_pkg::*;
#(
    //do not touch these parameters
    parameter EXT_DOMAINS_RND = core_v_mini_mcu_pkg::EXTERNAL_DOMAINS == 0 ? 1 : core_v_mini_mcu_pkg::EXTERNAL_DOMAINS,
    parameter NEXT_INT_RND = core_v_mini_mcu_pkg::NEXT_INT == 0 ? 1 : core_v_mini_mcu_pkg::NEXT_INT
) (
    input logic clk_i,
    input logic rst_ni,

    input  obi_req_t  slave_req_i,
    output obi_resp_t slave_resp_o,

    // SOC CTRL
    output logic [31:0] exit_value_o,

    // Memory Map SPI Region
    input  obi_req_t  spimemio_req_i,
    output obi_resp_t spimemio_resp_o,

    // POWER MANAGER
    input logic [31:0] intr_i,
    input logic [NEXT_INT_RND-1:0] intr_vector_ext_i,
    input logic core_sleep_i,
    output logic cpu_subsystem_powergate_switch_no,
    input logic cpu_subsystem_powergate_switch_ack_ni,
    output logic cpu_subsystem_powergate_iso_no,
    output logic cpu_subsystem_rst_no,
    output logic peripheral_subsystem_powergate_switch_no,
    input logic peripheral_subsystem_powergate_switch_ack_ni,
    output logic peripheral_subsystem_powergate_iso_no,
    output logic peripheral_subsystem_rst_no,
    output logic [core_v_mini_mcu_pkg::NUM_BANKS-1:0] memory_subsystem_banks_powergate_switch_no,
    input  logic [core_v_mini_mcu_pkg::NUM_BANKS-1:0] memory_subsystem_banks_powergate_switch_ack_ni,
    output logic [core_v_mini_mcu_pkg::NUM_BANKS-1:0] memory_subsystem_banks_powergate_iso_no,
    output logic [core_v_mini_mcu_pkg::NUM_BANKS-1:0] memory_subsystem_banks_set_retentive_no,
    output logic [EXT_DOMAINS_RND-1:0] external_subsystem_powergate_switch_no,
    input logic [EXT_DOMAINS_RND-1:0] external_subsystem_powergate_switch_ack_ni,
    output logic [EXT_DOMAINS_RND-1:0] external_subsystem_powergate_iso_no,
    output logic [EXT_DOMAINS_RND-1:0] external_subsystem_rst_no,
    output logic [EXT_DOMAINS_RND-1:0] external_ram_banks_set_retentive_no,

    // Clock gating signals
    output logic peripheral_subsystem_clkgate_en_no,
    output logic [core_v_mini_mcu_pkg::NUM_BANKS-1:0] memory_subsystem_clkgate_en_no,
    output logic [EXT_DOMAINS_RND-1:0] external_subsystem_clkgate_en_no,

    // DMA
    output obi_req_t  dma_read_ch0_req_o,
    input  obi_resp_t dma_read_ch0_resp_i,
    output obi_req_t  dma_write_ch0_req_o,
    input  obi_resp_t dma_write_ch0_resp_i,
    output obi_req_t  dma_addr_ch0_req_o,
    input  obi_resp_t dma_addr_ch0_resp_i,

    // External PADs
    output reg_req_t pad_req_o,
    input  reg_rsp_t pad_resp_i,

    // FAST INTR CTRL
    input  logic [14:0] fast_intr_i,
    output logic [14:0] fast_intr_o,

    // EXTERNAL PERIPH
    output reg_req_t ext_peripheral_slave_req_o,
    input  reg_rsp_t ext_peripheral_slave_resp_i,
    
    ${xheep.get_rh().get_node_ports(xheep.get_ao_node()).strip(",")}
);

  import core_v_mini_mcu_pkg::*;
  import tlul_pkg::*;
  import rv_plic_reg_pkg::*;

  reg_pkg::reg_req_t peripheral_req;
  reg_pkg::reg_rsp_t peripheral_rsp;

  reg_pkg::reg_req_t [core_v_mini_mcu_pkg::AO_PERIPHERAL_COUNT-1:0] ao_peripheral_slv_req;
  reg_pkg::reg_rsp_t [core_v_mini_mcu_pkg::AO_PERIPHERAL_COUNT-1:0] ao_peripheral_slv_rsp;

  tlul_pkg::tl_h2d_t rv_timer_tl_h2d;
  tlul_pkg::tl_d2h_t rv_timer_tl_d2h;

  logic [AO_PERIPHERAL_PORT_SEL_WIDTH-1:0] peripheral_select;

  logic use_spimemio;

  ${xheep.get_rh().get_node_local_signals(xheep.get_ao_node())}


  obi_pkg::obi_req_t slave_fifo_req_sel;
  obi_pkg::obi_resp_t slave_fifo_resp_sel;

  assign ext_peripheral_slave_req_o = ao_peripheral_slv_req[core_v_mini_mcu_pkg::EXT_PERIPHERAL_IDX];
  assign ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::EXT_PERIPHERAL_IDX] = ext_peripheral_slave_resp_i;

`ifdef REMOVE_OBI_FIFO

  assign slave_fifo_req_sel = slave_req_i;
  assign slave_resp_o       = slave_fifo_resp_sel;

`else

  obi_pkg::obi_req_t  slave_fifoin_req;
  obi_pkg::obi_resp_t slave_fifoin_resp;

  obi_pkg::obi_req_t  slave_fifoout_req;
  obi_pkg::obi_resp_t slave_fifoout_resp;

  obi_fifo obi_fifo_i (
      .clk_i,
      .rst_ni,
      .producer_req_i (slave_fifoin_req),
      .producer_resp_o(slave_fifoin_resp),
      .consumer_req_o (slave_fifoout_req),
      .consumer_resp_i(slave_fifoout_resp)
  );

  assign slave_fifo_req_sel = slave_fifoout_req;
  assign slave_fifoout_resp = slave_fifo_resp_sel;
  assign slave_fifoin_req   = slave_req_i;
  assign slave_resp_o       = slave_fifoin_resp;

`endif

  periph_to_reg #(
      .req_t(reg_pkg::reg_req_t),
      .rsp_t(reg_pkg::reg_rsp_t),
      .IW(1)
  ) periph_to_reg_i (
      .clk_i,
      .rst_ni,
      .req_i(slave_fifo_req_sel.req),
      .add_i(slave_fifo_req_sel.addr),
      .wen_i(~slave_fifo_req_sel.we),
      .wdata_i(slave_fifo_req_sel.wdata),
      .be_i(slave_fifo_req_sel.be),
      .id_i('0),
      .gnt_o(slave_fifo_resp_sel.gnt),
      .r_rdata_o(slave_fifo_resp_sel.rdata),
      .r_opc_o(),
      .r_id_o(),
      .r_valid_o(slave_fifo_resp_sel.rvalid),
      .reg_req_o(peripheral_req),
      .reg_rsp_i(peripheral_rsp)
  );

  addr_decode #(
      .NoIndices(core_v_mini_mcu_pkg::AO_PERIPHERAL_COUNT),
      .NoRules(core_v_mini_mcu_pkg::AO_PERIPHERAL_COUNT),
      .addr_t(logic [31:0]),
      .rule_t(addr_map_rule_pkg::addr_map_rule_t)
  ) i_addr_decode_soc_regbus_periph_xbar (
      .addr_i(peripheral_req.addr),
      .addr_map_i(core_v_mini_mcu_pkg::AO_PERIPHERAL_ADDR_RULES),
      .idx_o(peripheral_select),
      .dec_valid_o(),
      .dec_error_o(),
      .en_default_idx_i(1'b0),
      .default_idx_i('0)
  );

  reg_demux #(
      .NoPorts(core_v_mini_mcu_pkg::AO_PERIPHERAL_COUNT),
      .req_t  (reg_pkg::reg_req_t),
      .rsp_t  (reg_pkg::reg_rsp_t)
  ) reg_demux_i (
      .clk_i,
      .rst_ni,
      .in_select_i(peripheral_select),
      .in_req_i(peripheral_req),
      .in_rsp_o(peripheral_rsp),
      .out_req_o(ao_peripheral_slv_req),
      .out_rsp_i(ao_peripheral_slv_rsp)
  );

  soc_ctrl #(
      .reg_req_t(reg_pkg::reg_req_t),
      .reg_rsp_t(reg_pkg::reg_rsp_t)
  ) soc_ctrl_i (
      .clk_i,
      .rst_ni,
      .reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::SOC_CTRL_IDX]),
      .reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::SOC_CTRL_IDX]),
      .boot_select_i(${xheep.get_rh().use_source_as_sv("boot_select", xheep.get_ao_node())}),
      .execute_from_flash_i(${xheep.get_rh().use_source_as_sv("execute_from_flash", xheep.get_ao_node())}),
      .use_spimemio_o(use_spimemio),
      .exit_valid_o(${xheep.get_rh().use_source_as_sv("exit_valid", xheep.get_ao_node())}),
      .exit_value_o
  );

  boot_rom boot_rom_i (
      .reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::BOOTROM_IDX]),
      .reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::BOOTROM_IDX])
  );

  spi_subsystem spi_subsystem_i (
      .clk_i,
      .rst_ni,
      .use_spimemio_i(use_spimemio),
      .spimemio_req_i,
      .spimemio_resp_o,
      .yo_reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::SPI_MEMIO_IDX]),
      .yo_reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::SPI_MEMIO_IDX]),
      .ot_reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::SPI_FLASH_IDX]),
      .ot_reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::SPI_FLASH_IDX]),
      .spi_flash_sck_o(${xheep.get_rh().use_source_as_sv("spi_flash_sck_o", xheep.get_ao_node())}),
      .spi_flash_sck_en_o(${xheep.get_rh().use_source_as_sv("spi_flash_sck_en_o", xheep.get_ao_node())}),
      .spi_flash_csb_o({
        ${xheep.get_rh().use_source_as_sv("spi_flash_csb_1_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_csb_0_o", xheep.get_ao_node())}
      }),
      .spi_flash_csb_en_o({
        ${xheep.get_rh().use_source_as_sv("spi_flash_csb_1_en_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_csb_0_en_o", xheep.get_ao_node())}
      }),
      .spi_flash_sd_o({
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_3_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_2_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_1_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_0_o", xheep.get_ao_node())}
      }),
      .spi_flash_sd_en_o({
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_3_en_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_2_en_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_1_en_o", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_0_en_o", xheep.get_ao_node())}
      }),
      .spi_flash_sd_i({
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_3_i", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_2_i", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_1_i", xheep.get_ao_node())},
        ${xheep.get_rh().use_source_as_sv("spi_flash_sd_0_i", xheep.get_ao_node())}
      }),
      .spi_flash_intr_error_o(),
      .spi_flash_intr_event_o(${xheep.get_rh().use_source_as_sv("spi_flash_intr", xheep.get_ao_node())}),
      .spi_flash_rx_valid_o(${xheep.get_rh().use_source_as_sv("spi_flash_dma_rx", xheep.get_ao_node())}),
      .spi_flash_tx_ready_o(${xheep.get_rh().use_source_as_sv("spi_flash_dma_tx", xheep.get_ao_node())})
  );

  power_manager #(
      .reg_req_t(reg_pkg::reg_req_t),
      .reg_rsp_t(reg_pkg::reg_rsp_t)
  ) power_manager_i (
      .clk_i,
      .rst_ni,
      .reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::POWER_MANAGER_IDX]),
      .reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::POWER_MANAGER_IDX]),
      .intr_i,
      .ext_irq_i(intr_vector_ext_i),
      .core_sleep_i,
      .cpu_subsystem_powergate_switch_no,
      .cpu_subsystem_powergate_switch_ack_ni,
      .cpu_subsystem_powergate_iso_no,
      .cpu_subsystem_rst_no,
      .peripheral_subsystem_powergate_switch_no,
      .peripheral_subsystem_powergate_switch_ack_ni,
      .peripheral_subsystem_powergate_iso_no,
      .peripheral_subsystem_rst_no,
      .memory_subsystem_banks_powergate_switch_no,
      .memory_subsystem_banks_powergate_switch_ack_ni,
      .memory_subsystem_banks_powergate_iso_no,
      .memory_subsystem_banks_set_retentive_no,
      .external_subsystem_powergate_switch_no,
      .external_subsystem_powergate_switch_ack_ni,
      .external_subsystem_powergate_iso_no,
      .external_subsystem_rst_no,
      .external_ram_banks_set_retentive_no,
      .peripheral_subsystem_clkgate_en_no,
      .memory_subsystem_clkgate_en_no,
      .external_subsystem_clkgate_en_no
  );

  reg_to_tlul #(
      .req_t(reg_pkg::reg_req_t),
      .rsp_t(reg_pkg::reg_rsp_t),
      .tl_h2d_t(tlul_pkg::tl_h2d_t),
      .tl_d2h_t(tlul_pkg::tl_d2h_t),
      .tl_a_user_t(tlul_pkg::tl_a_user_t),
      .tl_a_op_e(tlul_pkg::tl_a_op_e),
      .TL_A_USER_DEFAULT(tlul_pkg::TL_A_USER_DEFAULT),
      .PutFullData(tlul_pkg::PutFullData),
      .Get(tlul_pkg::Get)
  ) rv_timer_reg_to_tlul_i (
      .tl_o(rv_timer_tl_h2d),
      .tl_i(rv_timer_tl_d2h),
      .reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::RV_TIMER_AO_IDX]),
      .reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::RV_TIMER_AO_IDX])
  );

  rv_timer rv_timer_0_1_i (
      .clk_i,
      .rst_ni,
      .tl_i(rv_timer_tl_h2d),
      .tl_o(rv_timer_tl_d2h),
      .intr_timer_expired_0_0_o(${xheep.get_rh().use_source_as_sv("rv_timer_0_intr", xheep.get_ao_node())}),
      .intr_timer_expired_1_0_o(${xheep.get_rh().use_source_as_sv("rv_timer_1_intr", xheep.get_ao_node())})
  );

  parameter DMA_TRIGGER_SLOT_NUM = ${xheep.get_rh().get_target_ep_copy("dma_default_target").count};
  logic [DMA_TRIGGER_SLOT_NUM-1:0] dma_trigger_slots;
  assign dma_trigger_slots = ${xheep.get_rh().use_target_as_sv_array_multi("dma_default_target", xheep.get_ao_node(), xheep.get_rh().get_target_ep_copy("dma_default_target").count)};

  dma #(
      .reg_req_t (reg_pkg::reg_req_t),
      .reg_rsp_t (reg_pkg::reg_rsp_t),
      .obi_req_t (obi_pkg::obi_req_t),
      .obi_resp_t(obi_pkg::obi_resp_t),
      .SLOT_NUM  (DMA_TRIGGER_SLOT_NUM)
  ) dma_i (
      .clk_i,
      .rst_ni,
      .reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::DMA_IDX]),
      .reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::DMA_IDX]),
      .dma_read_ch0_req_o,
      .dma_read_ch0_resp_i,
      .dma_write_ch0_req_o,
      .dma_write_ch0_resp_i,
      .dma_addr_ch0_req_o,
      .dma_addr_ch0_resp_i,
      .trigger_slot_i(dma_trigger_slots),
      .dma_done_intr_o(${xheep.get_rh().use_source_as_sv("dma_done_intr", xheep.get_ao_node())}),
      .dma_window_intr_o(${xheep.get_rh().use_source_as_sv("dma_window_intr", xheep.get_ao_node())})
  );

  assign pad_req_o = ao_peripheral_slv_req[core_v_mini_mcu_pkg::PAD_CONTROL_IDX];
  assign ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::PAD_CONTROL_IDX] = pad_resp_i;

  fast_intr_ctrl #(
      .reg_req_t(reg_pkg::reg_req_t),
      .reg_rsp_t(reg_pkg::reg_rsp_t)
  ) fast_intr_ctrl_i (
      .clk_i,
      .rst_ni,
      .reg_req_i(ao_peripheral_slv_req[core_v_mini_mcu_pkg::FAST_INTR_CTRL_IDX]),
      .reg_rsp_o(ao_peripheral_slv_rsp[core_v_mini_mcu_pkg::FAST_INTR_CTRL_IDX]),
      .fast_intr_i,
      .fast_intr_o
  );


endmodule : ao_peripheral_subsystem
