# ============================================================================
# cmsis-download.cmake — "the file that downloads everything"
# ============================================================================
#
# Given DEVICE (e.g. "STM32F446RE", set in base-setup.cmake via
# stm32_project()), this file:
#
#   1. parses the device name into family/model/flash-size-letter,
#   2. detects a chip switch across reconfigures and wipes stale vendored
#      files + the build dir if so,
#   3. fetches (or reuses already-vendored) CMSIS device headers, startup
#      code, the vector table, and an SVD from STM32-base_files,
#   4. picks and renders the right linker script template for this family.
#
# The two generated headers flash_config.h / irq_registry_config.h are
# NOT produced here — they're drivers-only, so STM32_Drivers_CPP generates
# them itself. Pulling in the drivers is a separate concern and lives in the
# main CMakeLists.txt (the DRIVERS section).
#
# Every file this pulls in or generates lands under
# cmsis-core/download_files/ and is meant to be committed once vendored —
# see ARCHITECTURE.md §04.4. download_one() (functions.cmake) is what makes
# step 3 a no-op after the first configure for a given chip.
# ============================================================================

include(${CMAKE_SOURCE_DIR}/cmake/functions.cmake)

# ============================================================================
# 1. Parse the device name
# ============================================================================
# STM32 part numbers follow: STM32 <family:2> <type:2-3> <pins:1> <flash:1> ...
# e.g. STM32F446RE  =  STM32 | F4 | 46 | R (pins) | E (flash size code)
# We only ever need three slices of it:
#   STM32_CORE      = first 7 chars  = "STM32F4"    (family, e.g. selects
#                                                     which -map.cmake/vector
#                                                     table directory to use)
#   STM32_MODEL_UC  = first 9 chars  = "STM32F446"  (family + type, used to
#                                                     look up the exact chip
#                                                     row in the family map)
#   last_letter     = char 10        = "E"          (flash-size code letter,
#                                                     used to name the linker
#                                                     script: STM32F446xE.ld)
# This is positional string-slicing, not a real parser — it assumes DEVICE is
# always an 11-character part number in this exact grammar (family+type+
# pins+flash letter). A device name that's shorter/longer or doesn't follow
# this grammar (e.g. a part without a package-size letter) will slice wrong
# without any error — there's no validation against the STM32 naming scheme
# here, only against whether the sliced name exists in the family map below.
string(SUBSTRING "${DEVICE}" 0 11 DEVICE)

string(TOLOWER ${DEVICE} STM32_DEVICE_LC)
string(TOUPPER ${DEVICE} STM32_DEVICE_UC)
message(STATUS "Device_LC: " ${STM32_DEVICE_LC})
message(STATUS "Device_UC: " ${STM32_DEVICE_UC})

string(SUBSTRING "${STM32_DEVICE_UC}" 0 7 STM32_CORE)
string(SUBSTRING "${STM32_DEVICE_UC}" 0 11 STM32_FLASH_def) # todo
string(SUBSTRING "${STM32_DEVICE_UC}" 0 9 STM32_MODEL_UC)
string(SUBSTRING "${STM32_DEVICE_UC}" 10 1 last_letter)

set(STM32_SERIES_UC "${STM32_CORE}xx")
set(linker_name "${STM32_MODEL_UC}x${last_letter}.ld")
string(TOLOWER ${STM32_MODEL_UC} STM32_MODEL_LC)
string(TOLOWER ${STM32_SERIES_UC} STM32_SERIES_LC)
set(c_target "${STM32_MODEL_UC}xx") # todo choose base on STM32_CORE

message(STATUS "STM32_CORE: 	 " ${STM32_CORE})
message(STATUS "STM32_FLASH_def:" ${STM32_FLASH_def})
message(STATUS "STM32_SERIES_UC: " ${STM32_SERIES_UC})
message(STATUS "STM32_SERIES_LC: " ${STM32_SERIES_LC})
message(STATUS "STM32_MODEL_UC: " ${STM32_MODEL_UC})
message(STATUS "STM32_MODEL_LC: " ${STM32_MODEL_LC})
message(STATUS "linker_name: " ${linker_name}) # todo
message(STATUS "last_letter: " ${last_letter}) # todo
message(STATUS "c_target: " ${c_target})

# ============================================================================
# 2. Device-change detection
# ============================================================================
# STM32_CONFIGURED_DEVICE remembers, in the CMake cache, which chip the
# *current build directory* was last configured for. If DEVICE changed since
# then, every previously vendored/generated file (linker script, headers,
# flash_config.h, ...) belongs to the old chip and must not be reused — so we
# wipe cmsis-core/download_files/ and the build dir before re-vendoring.
if(NOT DEFINED STM32_CONFIGURED_DEVICE)
  # First configuration
  message(STATUS
    "Initial STM32 configuration for device: ${DEVICE}"
  )

  set(STM32_CONFIGURED_DEVICE
      "${DEVICE}"
      CACHE STRING
      "STM32 device this build directory was configured for"
  )

else()
	# Reconfiguration
	if(NOT STM32_CONFIGURED_DEVICE STREQUAL DEVICE)
		message(WARNING
		"STM32 device changed:\n"
		"  old: ${STM32_CONFIGURED_DEVICE}\n"
		"  new: ${DEVICE}\n"
		"Cleaning downloaded STM32 files."
		)

		file(REMOVE_RECURSE
		${CMAKE_SOURCE_DIR}/cmsis-core/download_files
		${CMAKE_SOURCE_DIR}/cmsis-core/generated
		)

		# Clean build artifacts
		stm32_clean_build_dir()

		set(STM32_CONFIGURED_DEVICE
			"${DEVICE}"
			CACHE STRING
			"STM32 device this build directory was configured for"
			FORCE
		)
	else()
		message(STATUS
		"STM32 device unchanged: ${DEVICE}"
		)
	endif()
endif()



# ============================================================================
# 3. Vendor CMSIS / startup / vector / SVD files for this device
# ============================================================================
# Each download_one() below is a no-op once the destination is vendored
# (see functions.cmake) — this whole section only does real network work on
# the first configure for a given DEVICE.

# ----------------------------------------------------------------------------
# get name for vector table and header file
# ----------------------------------------------------------------------------
download_one(
	"STM32-map.cmake"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/cmake"
	"cmake/${STM32_CORE}-map.cmake")

include(${CMAKE_SOURCE_DIR}/cmsis-core/download_files/cmake/STM32-map.cmake)
# ============================
# lookup name
# ============================
list(FIND ${STM32_CORE}_MAP "${STM32_DEVICE_UC}" IDX)

if(IDX LESS 0)
  message(FATAL_ERROR "No Name for ${STM32_DEVICE_UC}")
endif()

math(EXPR IDX_NAME   "${IDX} + 1")
math(EXPR IDX_FLASH  "${IDX} + 2")
math(EXPR IDX_RAM    "${IDX} + 3")
math(EXPR IDX_EXTRA  "${IDX} + 4")

list(GET ${STM32_CORE}_MAP ${IDX_NAME}  STM32_NAME)
list(GET ${STM32_CORE}_MAP ${IDX_FLASH} STM32_FLASH)
list(GET ${STM32_CORE}_MAP ${IDX_RAM}   STM32_RAM)
list(GET ${STM32_CORE}_MAP ${IDX_EXTRA} STM32_EXTRA)

message(STATUS "STM32_NAME   = ${STM32_NAME}")

# ----------------------------------------------------------------------------
# download svd from series and model - STM32F4/STM32F4xx.svd
# ----------------------------------------------------------------------------

download_one(
	"SVD.svd"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files"
	"SVD/${STM32_SERIES_UC}/${STM32_MODEL_UC}.svd")

# ----------------------------------------------------------------------------
# download startup and vector files
# ----------------------------------------------------------------------------

download_one(
	"startup_common.c"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup"
	"startup_c/startup_common.c")

download_one(
	"vector_${STM32_NAME}.c"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup"
	"startup_c/${STM32_SERIES_UC}/vector_${STM32_NAME}.c")

# Path to the downloaded vector table - the exe compiles it (it's the real
# .isr_vector), and STM32_Drivers_CPP scrapes it to generate its IRQ stubs.
set(STM32_VECTOR_FILE "${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/vector_${STM32_NAME}.c")

# ----------------------------------------------------------------------------
# download STM32 headers files and system files
# ----------------------------------------------------------------------------

download_one(
	"${STM32_SERIES_LC}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/${STM32_SERIES_LC}.h")

download_one(
	"system_${STM32_SERIES_LC}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/system_${STM32_SERIES_LC}.h")

download_one(
	"system_${STM32_SERIES_LC}.c"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Source"
	"Device/${STM32_SERIES_UC}/Source/system_${STM32_SERIES_LC}.c")

download_one(
	"${STM32_NAME}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/${STM32_NAME}.h")

# ============================================================================
# 4. Linker script: pick a template per family, render it for this device
# ============================================================================

message(STATUS "Using linker script : ${LD_TEMPLATE}")
message(STATUS "FLASH               : ${STM32_FLASH}")
message(STATUS "RAM                 : ${STM32_RAM}")
message(STATUS "EXTRA               : ${STM32_EXTRA}")

set(FLASH_ORIGIN 0x08000000)
set(FLASH_LENGTH ${STM32_FLASH})

set(RAM_ORIGIN 0x20000000)
set(RAM_LENGTH ${STM32_RAM})

if(NOT DEFINED HEAP_SIZE)
	set(HEAP_SIZE 0x200)
endif()
if(NOT DEFINED STACK_SIZE)
	set(STACK_SIZE 0x400)
endif()

# Every family below needs a different MEMORY{} layout because the extra
# RAM region (or lack of one) differs: F7 splits RAM into ITCM/DTCM/SRAM1/
# SRAM2, H7 has its own (not yet implemented — see the TODO below), anything
# with a nonzero STM32_EXTRA gets a CCM region bolted on, everything else is
# a plain FLASH+RAM chip.
if(STM32_CORE STREQUAL "STM32F7")
	set(LD_TEMPLATE "linker-f7.ld.in")

	set(ITCM_ORIGIN 0x00000000)
	set(ITCM_LENGTH 16K)

	set(DTCM_ORIGIN 0x20000000)
	set(DTCM_LENGTH ${STM32_EXTRA})   # 64K или 128K

	set(SRAM2_LENGTH 16K)

	if(STM32_EXTRA STREQUAL "64K")
		set(SRAM2_ORIGIN 0x2004C000)

		set(SRAM1_ORIGIN 0x20010000)
	elseif(STM32_EXTRA STREQUAL "128K")
		set(SRAM2_ORIGIN 0x2007C000)

		set(SRAM1_ORIGIN 0x20020000)
	else()
		message(FATAL_ERROR "Invalid DTCM size for F7: ${STM32_EXTRA}")
	endif()

	k_to_int("${STM32_RAM}"   RAM_K)
	k_to_int("${DTCM_LENGTH}" DTCM_K)
	k_to_int("${SRAM2_LENGTH}" SRAM2_K)

	math(EXPR SRAM1_K
		"${RAM_K} - ${DTCM_K} - ${SRAM2_K}"
	)

	set(SRAM1_LENGTH "${SRAM1_K}K")

elseif(STM32_CORE STREQUAL "STM32H7")
	# TODO: STM32-base_files/linker/ has no linker-h7.ld.in yet (only
	# linker-simple/-f7/-ccm exist) — selecting an H7 device will fail below
	# at download_one("linker-h7.ld.in", ...) with a 404, not a clear
	# "H7 unsupported" error. Fix upstream before advertising H7 support.
	set(LD_TEMPLATE "linker-h7.ld.in")
elseif(STM32_EXTRA AND NOT STM32_EXTRA STREQUAL "-" AND NOT STM32_EXTRA STREQUAL "0K")
	set(LD_TEMPLATE "linker-ccm.ld.in")

	set(CCM_ORIGIN 0x10000000)
	set(CCM_LENGTH ${STM32_EXTRA})

	k_to_int("${STM32_RAM}"   RAM_K)
	k_to_int("${CCM_LENGTH}"  CCM_K)

	math(EXPR SRAM1_K
		"${RAM_K} - ${CCM_K}"
	)

	set(RAM_LENGTH "${SRAM1_K}K")
else()
	set(LD_TEMPLATE "linker-simple.ld.in")
endif()


download_one(
	"${LD_TEMPLATE}"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker"
	"linker/${LD_TEMPLATE}")

set(LD_IN  ${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker/${LD_TEMPLATE})
set(LD_OUT ${CMAKE_SOURCE_DIR}/cmsis-core/generated/linker/${STM32_DEVICE_LC}.ld)

configure_file(
  ${LD_IN}
  ${LD_OUT}
  @ONLY
)


message(STATUS "Linker script generated: ${LD_OUT}")

# flash_config.h (sector map) and irq_registry_config.h (IRQ dispatch stubs)
# are NOT generated here anymore - both are consumed only by STM32_Drivers_CPP
# (irq_registry_config.h doesn't even compile without it), so the drivers
# CMakeLists generates them itself from the chip facts this file exposes
# (STM32_CORE / STM32_FLASH / STM32_SERIES_UC / STM32_NAME / STM32_VECTOR_FILE
# / ${STM32_CORE}_SECTOR_MAP). Drivers are pulled in from the main
# CMakeLists.txt (the DRIVERS section).
