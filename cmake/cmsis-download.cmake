# ============================================================================
# cmsis-download.cmake - download files for the chip and parse its parameters
# ============================================================================
# A procedural file, include()'d from CMakeLists.txt after project(). Driven
# by CFG_device (from project.json):
#
#   1. splits the device name into family/model/flash-size letter,
#   2. catches a chip change between reconfigures and, if there was one,
#      wipes the stale downloaded files and the build directory,
#   3. downloads (or reuses already-present) CMSIS headers, startup code,
#      the vector table, and the SVD from STM32-base_files,
#   4. picks a linker script template for this family.
#
# Compiler/linker flags (the stm32_platform target) and wiring up drivers are
# NOT here - that is CMakeLists.txt's job; this file only fetches files and facts.
#
# Output (read by CMakeLists.txt, stm32_add_firmware(), Drivers/CMakeLists):
#   main_cpu_PARAMS  c_target  STM32_DEVICE_UC  STM32_CORE  STM32_FLASH
#   STM32_RAM  STM32_EXTRA  STM32_SERIES_UC  STM32_NAME  STM32_VECTOR_FILE
#   STM32_LINKER_TEMPLATE  STM32_STARTUP_SRCS  STM32_FLASH_SECTORS
#   HEAP_SIZE  STACK_SIZE  RAM_ORIGIN  RAM_LENGTH  (+ the family's MEMORY variables)
#
# functions.cmake must be include()'d earlier (CMakeLists.txt does this).
# Everything downloaded lands in cmsis-core/download_files/ and is committed
# after the first download; download_one() makes step 3 a no-op on later
# configures.
# ============================================================================

# ============================================================================
# 1. Parsing the device name
# ============================================================================
# STM32 part numbers are laid out as: STM32 <family:2> <type:2-3> <package:1>
# <flash:1> ...  e.g. STM32F446RE = STM32 | F4 | 46 | R (package) | E (flash
# size code). We only ever need three slices:
#   STM32_CORE      = first 7 chars  = "STM32F4"    (family: e.g. selects
#                                                      which -map.cmake/vector
#                                                      directory to use)
#   STM32_MODEL_UC  = first 9 chars  = "STM32F446"  (family + type, used to
#                                                      look up the exact chip
#                                                      string in the map)
#   last_letter     = 10th character = "E"          (flash size code letter,
#                                                      goes into the linker
#                                                      script name:
#                                                      STM32F446xE.ld)
# This is a positional slice of the string, not a real parser - it assumes
# CFG_device is always an 11-character part number following exactly this
# grammar (family+type+package+flash letter). A name that is shorter, longer,
# or does not follow the grammar (e.g. a part with no package letter) gets
# sliced wrong with no error - there is no check against the STM32 naming
# scheme here, only a check that the sliced name exists in the family's map
# table below.
string(SUBSTRING "${CFG_device}" 0 11 STM32_DEVICE)

string(TOLOWER ${STM32_DEVICE} STM32_DEVICE_LC)
string(TOUPPER ${STM32_DEVICE} STM32_DEVICE_UC)
message(STATUS "Device_LC: " ${STM32_DEVICE_LC})
message(STATUS "Device_UC: " ${STM32_DEVICE_UC})

string(SUBSTRING "${STM32_DEVICE_UC}" 0 7 STM32_CORE)
string(SUBSTRING "${STM32_DEVICE_UC}" 0 11 STM32_FLASH_def) # todo
string(SUBSTRING "${STM32_DEVICE_UC}" 0 9 STM32_MODEL_UC)
string(SUBSTRING "${STM32_DEVICE_UC}" 10 1 last_letter)     # flash size code letter

set(STM32_SERIES_UC "${STM32_CORE}xx")
set(linker_name "${STM32_MODEL_UC}x${last_letter}.ld")
string(TOLOWER ${STM32_MODEL_UC} STM32_MODEL_LC)
string(TOLOWER ${STM32_SERIES_UC} STM32_SERIES_LC)
set(c_target "${STM32_MODEL_UC}xx") # todo: pick based on STM32_CORE

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
# 2. Device change
# ============================================================================
# Files downloaded for a different chip (or with no marker) get wiped, and
# the marker is refreshed - all the logic lives in stm32_sync_device()
# (functions.cmake).
stm32_sync_device("${STM32_DEVICE}")

# ============================================================================
# 3. Downloading CMSIS / startup / vectors / SVD for this device
# ============================================================================
# Every download_one() below is a no-op once the file is already there (see
# functions.cmake) - actual network activity in this section only happens on
# the first configure for a given DEVICE.

# ----------------------------------------------------------------------------
# get the name for the vector table and the header file
# ----------------------------------------------------------------------------
download_one(
	"STM32-map.cmake"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/cmake"
	"cmake/${STM32_CORE}-map.cmake")

include(${CMAKE_SOURCE_DIR}/cmsis-core/download_files/cmake/STM32-map.cmake)
# ============================
# name lookup
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

# The erase-sector layout for this specific flash size - a ready-made
# "addr;size;..." list, appended to the same map file by the
# STM32-base_files/flash_sectors.py script. Read by stm32_flash_window()
# and stm32_add_firmware() (both in functions.cmake), and by the drivers'
# flash_config.h.
set(STM32_FLASH_SECTORS "${${STM32_CORE}_SECTORS_${STM32_FLASH}}")
if(NOT STM32_FLASH_SECTORS)
	message(FATAL_ERROR
		"cmsis-download: ${STM32_CORE}_SECTORS_${STM32_FLASH} not found for "
		"${STM32_DEVICE_UC} (${STM32_FLASH}). Regenerate the map tables with "
		"STM32-base_files/flash_sectors.py.")
endif()

# ----------------------------------------------------------------------------
# download the SVD by series and model - STM32F4/STM32F4xx.svd
# ----------------------------------------------------------------------------

download_one(
	"SVD.svd"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files"
	"SVD/${STM32_SERIES_UC}/${STM32_MODEL_UC}.svd"
	OPTIONAL)   # the SVD is only needed by the debugger; missing is not an error

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

# Path to the downloaded vector table - the executable compiles it (this is
# the real .isr_vector), and STM32_Drivers_CPP parses it as text to generate
# its own IRQ stubs.
set(STM32_VECTOR_FILE "${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/vector_${STM32_NAME}.c")

# The mandatory runtime that every firmware image links - same category as
# the linker script - vector table + shared startup, plus newlib retarget
# stubs (sysmem.c = _sbrk/heap, syscalls.c = _write/_read/...).
# stm32_add_firmware() adds this to every target it builds.
set(STM32_STARTUP_SRCS
	${STM32_VECTOR_FILE}
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/startup_common.c
	${CMAKE_SOURCE_DIR}/no_system_files/sysmem.c
	${CMAKE_SOURCE_DIR}/no_system_files/syscalls.c
)

# ----------------------------------------------------------------------------
# download STM32 headers and system files
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
# 4. Linker script: pick a template per family (rendered by stm32_add_firmware)
# ============================================================================
# FLASH_ORIGIN / FLASH_LENGTH are NOT set here - they depend on the start
# sector of the image being linked (bootloader or application), so
# stm32_add_firmware() resolves them per target and renders the linker
# script there too.

message(STATUS "FLASH : ${STM32_FLASH}   RAM : ${STM32_RAM}   EXTRA : ${STM32_EXTRA}")

set(RAM_ORIGIN 0x20000000)
set(RAM_LENGTH ${STM32_RAM})

# heap/stack come from project.json (stm32_read_config already filled in the defaults)
set(HEAP_SIZE  ${CFG_heap})
set(STACK_SIZE ${CFG_stack})

# Each family below needs its own MEMORY{} layout, because the extra RAM
# region (or lack of one) differs across all of them: F7 splits RAM into
# ITCM/DTCM/SRAM1/SRAM2, H7 has its own (not implemented yet - see the TODO
# below), anything with a non-zero STM32_EXTRA gets a bolted-on CCM region,
# everything else is a plain chip with just FLASH+RAM.
if(STM32_CORE STREQUAL "STM32F7")
	set(LD_TEMPLATE "linker-f7.ld.in")

	set(ITCM_ORIGIN 0x00000000)
	set(ITCM_LENGTH 16K)

	set(DTCM_ORIGIN 0x20000000)
	set(DTCM_LENGTH ${STM32_EXTRA})   # 64K or 128K

	if(NOT STM32_EXTRA STREQUAL "64K" AND NOT STM32_EXTRA STREQUAL "128K")
		message(FATAL_ERROR "Invalid DTCM size for F7: ${STM32_EXTRA}")
	endif()

	# SRAM1 / SRAM2 placement comes straight from ST's own CMSIS header:
	# SRAM1_BASE / SRAM2_BASE and the SRAM2 size in its comment. F72x/F73x,
	# F74x/F75x, and F76x/F77x each place it differently (SRAM2 sits at
	# 0x2003C000 / 0x2004C000 / 0x2007C000), a hardcoded address would only
	# fit one of the groups.
	set(_f7_hdr "${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include/${STM32_NAME}.h")
	file(STRINGS "${_f7_hdr}" _f7_sram REGEX "^#define[ \t]+SRAM[12]_BASE[ \t]")
	set(SRAM1_ORIGIN "")
	set(SRAM2_ORIGIN "")
	set(SRAM2_LENGTH 16K)
	foreach(_l ${_f7_sram})
		if(_l MATCHES "SRAM1_BASE[ \t]+(0x[0-9A-Fa-f]+)")
			set(SRAM1_ORIGIN "${CMAKE_MATCH_1}")
		elseif(_l MATCHES "SRAM2_BASE[ \t]+(0x[0-9A-Fa-f]+)")
			set(SRAM2_ORIGIN "${CMAKE_MATCH_1}")
			if(_l MATCHES "([0-9]+)[ \t]*KB[ \t]+RAM2")
				set(SRAM2_LENGTH "${CMAKE_MATCH_1}K")
			endif()
		endif()
	endforeach()
	if(SRAM1_ORIGIN STREQUAL "" OR SRAM2_ORIGIN STREQUAL "")
		message(FATAL_ERROR
			"F7: SRAM1_BASE / SRAM2_BASE not found in ${_f7_hdr} (needed for the memory map)")
	endif()

	# SRAM1 runs up to where SRAM2 starts
	math(EXPR SRAM1_K "(${SRAM2_ORIGIN} - ${SRAM1_ORIGIN}) / 1024")
	set(SRAM1_LENGTH "${SRAM1_K}K")

elseif(STM32_CORE STREQUAL "STM32H7")
	# TODO: STM32-base_files/linker/ does not have linker-h7.ld.in yet (only
	# linker-simple/-f7/-ccm) - selecting an H7 device will fail below at
	# download_one("linker-h7.ld.in", ...) with a 404, not with a clear
	# "H7 is not supported" error. Fix upstream before claiming H7 support.
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


message(STATUS "Linker template : ${LD_TEMPLATE}")

download_one(
	"${LD_TEMPLATE}"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker"
	"linker/${LD_TEMPLATE}")

# Template only - stm32_add_firmware() renders it for each target (every
# image sets its own FLASH_ORIGIN / FLASH_LENGTH from its own start sector).
set(STM32_LINKER_TEMPLATE  ${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker/${LD_TEMPLATE})


# flash_config.h (the sector map) and irq_registry_config.h (IRQ dispatcher
# stubs) are NOT generated here - both are only needed by STM32_Drivers_CPP
# (irq_registry_config.h is not even compiled without it), so the drivers'
# own CMakeLists generates them from the chip facts this file exposes
# (STM32_CORE / STM32_FLASH / STM32_SERIES_UC / STM32_NAME / STM32_VECTOR_FILE
# / STM32_FLASH_SECTORS). The stm32_platform target and wiring up drivers
# live in the main CMakeLists.txt.
