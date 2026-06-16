###################################################
# EDGE ANALYTICS IP SYNTHESIS SCRIPT
# Cadence Genus - 90nm Technology
###################################################

###################################################
# SET LIBRARY PATH
###################################################
set_db init_lib_search_path /cadence/install/FOUNDRY-01/digital/90nm/dig/lib

###################################################
# READ LIBRARY
###################################################
read_libs slow.lib

###################################################
# READ RTL FILES
###################################################
read_hdl ea_stim_gen.v
read_hdl ea_ma_filter.v
read_hdl ea_feature_ext.v
read_hdl ea_fft_engine.v
read_hdl ea_anomaly.v
read_hdl ea_decision.v
read_hdl ea_ml_fvec.v
read_hdl ea_top.v

###################################################
# ELABORATE TOP MODULE
###################################################
elaborate ea_top

###################################################
# READ CONSTRAINT FILE
###################################################
read_sdc constraints.sdc

###################################################
# CHECK DESIGN
###################################################
check_design

###################################################
# SYNTHESIS FLOW
###################################################
syn_gen
syn_map
syn_opt

###################################################
# REPORTS
###################################################
report_area > ea_top_area.rpt
report_timing > ea_top_timing.rpt
report_power > ea_top_power.rpt

###################################################
# WRITE NETLIST
###################################################
write_hdl > ea_top_netlist.v

###################################################
# WRITE SDC
###################################################
write_sdc > ea_top_postsyn.sdc
