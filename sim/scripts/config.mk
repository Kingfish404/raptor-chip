#***************************************************************************************
# Copyright (c) 2014-2022 Zihao Yu, Nanjing University
#
# NEMU is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#          http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
#
# See the Mulan PSL v2 for more details.
#**************************************************************************************/

# Kconfig itself still uses relative scratch/dependency paths internally, so
# changing KCONFIG_CONFIG alone is insufficient. Run it inside SIM_CONFIG_ROOT.
SIM_CONFIG_DRIVER = python3 "$(NSIM_HOME)/scripts/configure.py" --source "$(NSIM_HOME)" --output "$(SIM_CONFIG_ROOT)" --default "$(strip $(NPC_DEFCONFIG))"
SIM_CONFIG_GOALS := $(if $(MAKECMDGOALS),$(filter all run run_log sim print-npc-exec print-jtag-bin jtag-selftest jtag-openocd,$(MAKECMDGOALS)),all)
ifneq ($(SIM_CONFIG_GOALS),)
ifneq ($(filter %defconfig menuconfig,$(MAKECMDGOALS)),)
$(error Configure and build in separate make invocations using the same BUILD_PROFILE/VFLAGS)
endif
$(SIM_AUTOCONFIG) $(SIM_AUTOHEADER) &: $(NSIM_HOME)/Kconfig $(wildcard $(SIM_CONFIG_FILE))
	@$(SIM_CONFIG_DRIVER)
endif

menuconfig: ## Edit only the selected build profile/XLEN configuration
	@$(SIM_CONFIG_DRIVER) --menu

savedefconfig: ## Save the selected configuration into its build directory
	@$(SIM_CONFIG_DRIVER) --save "$(SIM_CONFIG_ROOT)/defconfig"

%defconfig:
	@$(SIM_CONFIG_DRIVER) --defconfig "$@"

.PHONY: menuconfig savedefconfig defconfig print-config
print-config: ## Show the build-local Kconfig and generated-header paths
	@printf '%s\n' '$(SIM_CONFIG_FILE)' '$(SIM_AUTOHEADER)'
