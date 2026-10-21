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
# Validate and normalize ordering-code suffixes before looking up the exact
# chip row. CMSIS selectors are resolved from that row, not from these slices.
string(TOUPPER "${CFG_device}" _device_code)
if(_device_code MATCHES "^STM32H7")
	message(FATAL_ERROR "STM32H7 is not supported: no platform linker/runtime layout is implemented")
endif()
if(NOT _device_code MATCHES "^STM32[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]([A-Z]([0-9](TR)?)?)?$")
	message(FATAL_ERROR "Invalid STM32 ordering code '${CFG_device}': expected an 11-character MCU code, optionally followed by package/temperature suffix (e.g. T6 or T6TR)")
endif()
string(SUBSTRING "${_device_code}" 0 11 STM32_DEVICE)

string(TOLOWER ${STM32_DEVICE} STM32_DEVICE_LC)
string(TOUPPER ${STM32_DEVICE} STM32_DEVICE_UC)
message(STATUS "Device_LC: " ${STM32_DEVICE_LC})
message(STATUS "Device_UC: " ${STM32_DEVICE_UC})

string(SUBSTRING "${STM32_DEVICE_UC}" 0 7 STM32_CORE)
set(_supported_families STM32F0 STM32F1 STM32F2 STM32F3 STM32F4 STM32F7 STM32G0 STM32G4 STM32L0 STM32L1)
if(NOT STM32_CORE IN_LIST _supported_families)
	message(FATAL_ERROR "Unsupported STM32 family '${STM32_CORE}'")
endif()
string(SUBSTRING "${STM32_DEVICE_UC}" 0 11 STM32_FLASH_def) # todo
string(SUBSTRING "${STM32_DEVICE_UC}" 0 9 STM32_MODEL_UC)
string(SUBSTRING "${STM32_DEVICE_UC}" 10 1 last_letter)     # flash size code letter

set(STM32_SERIES_UC "${STM32_CORE}xx")
set(linker_name "${STM32_MODEL_UC}x${last_letter}.ld")
string(TOLOWER ${STM32_MODEL_UC} STM32_MODEL_LC)
string(TOLOWER ${STM32_SERIES_UC} STM32_SERIES_LC)

message(STATUS "STM32_CORE: 	 " ${STM32_CORE})
message(STATUS "STM32_FLASH_def:" ${STM32_FLASH_def})
message(STATUS "STM32_SERIES_UC: " ${STM32_SERIES_UC})
message(STATUS "STM32_SERIES_LC: " ${STM32_SERIES_LC})
message(STATUS "STM32_MODEL_UC: " ${STM32_MODEL_UC})
message(STATUS "STM32_MODEL_LC: " ${STM32_MODEL_LC})
message(STATUS "linker_name: " ${linker_name}) # todo
message(STATUS "last_letter: " ${last_letter}) # todo

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
math(EXPR IDX_LAYOUT "${IDX} + 5")

list(GET ${STM32_CORE}_MAP ${IDX_NAME}  STM32_NAME)
list(GET ${STM32_CORE}_MAP ${IDX_FLASH} STM32_FLASH)
list(GET ${STM32_CORE}_MAP ${IDX_RAM}   STM32_RAM)
list(GET ${STM32_CORE}_MAP ${IDX_EXTRA} STM32_EXTRA)
list(GET ${STM32_CORE}_MAP ${IDX_LAYOUT} STM32_FLASH_LAYOUT)

# The CMSIS selector comes from the same row as the header/vector. Only x
# placeholders stay lowercase (STM32F401xE, STM32F412Zx, STM32L152xCA, ...).
string(TOUPPER "${STM32_NAME}" c_target)
string(REPLACE "X" "x" c_target "${c_target}")
message(STATUS "CMSIS target = ${c_target}")

message(STATUS "STM32_NAME   = ${STM32_NAME}")

# FLASH_LAYOUT is the last column of the selected model/density row. Its token
# names a geometry (e.g. STM32F4_BANKED), not the compiler's STM32F4 family define.
# The device row selects a shared Flash layout. Existing single/dual erase
# lists define its supported modes; there is no separate lookup table.
if(NOT STM32_FLASH_LAYOUT_VERSION EQUAL 3)
	message(FATAL_ERROR "Outdated STM32 map: refresh STM32-map.cmake from STM32-base_files (Flash layout format 3)")
endif()
set(_bank_modes "")
foreach(_mode single dual)
	if(DEFINED ${STM32_FLASH_LAYOUT}_ERASE_${_mode}_${STM32_FLASH})
		list(APPEND _bank_modes ${_mode})
	endif()
endforeach()
if(NOT _bank_modes)
	message(FATAL_ERROR "No Flash bank modes for ${STM32_DEVICE_UC} (${STM32_NAME}, ${STM32_FLASH})")
endif()
list(LENGTH _bank_modes _mode_count)
# One supported mode is mandatory automatically; two modes default to single.
# Explicit project.json flash_bank_mode must match an available erase list.
# This selects image geometry only; the Flash driver checks actual MCU option bits.
set(STM32_FLASH_BANK_MODE "${CFG_flash_bank_mode}")
if(STM32_FLASH_BANK_MODE STREQUAL "")
	if(_mode_count EQUAL 1)
		list(GET _bank_modes 0 STM32_FLASH_BANK_MODE)
	else()
		set(STM32_FLASH_BANK_MODE single)
	endif()
endif()
if(NOT STM32_FLASH_BANK_MODE IN_LIST _bank_modes)
	message(FATAL_ERROR "${STM32_DEVICE_UC}: flash_bank_mode '${STM32_FLASH_BANK_MODE}' is unsupported; available: ${_bank_modes}")
endif()
set(STM32_DUAL_BANK OFF)
if(STM32_FLASH_BANK_MODE STREQUAL "dual")
	set(STM32_DUAL_BANK ON)
endif()
set(STM32_FLASH_BANK_SWITCHABLE OFF)
if(_mode_count GREATER 1)
	set(STM32_FLASH_BANK_SWITCHABLE ON)
endif()
set(STM32_FLASH_ERASE_UNITS "${${STM32_FLASH_LAYOUT}_ERASE_${STM32_FLASH_BANK_MODE}_${STM32_FLASH}}")
list(LENGTH STM32_FLASH_ERASE_UNITS _unit_fields)
math(EXPR _unit_remainder "${_unit_fields} % 4")
if(NOT _unit_fields OR NOT _unit_remainder EQUAL 0)
	message(FATAL_ERROR "Invalid Flash erase map for ${STM32_DEVICE_UC}, ${STM32_FLASH_BANK_MODE}")
endif()
set(STM32_FLASH_SECTORS "")
set(STM32_FLASH_HAS_GAP OFF)
set(STM32_FLASH_BANK1_ORIGIN "")
set(STM32_FLASH_BANK1_END "")
set(STM32_FLASH_BANK2_ORIGIN "")
set(STM32_FLASH_BANK2_END "")
set(_seen_banks "")
set(_units ${STM32_FLASH_ERASE_UNITS})
set(_previous_end "")
while(_units)
	list(POP_FRONT _units _address _size _bank _number)
	math(EXPR _end "${_address} + ${_size}")
	if(NOT _previous_end STREQUAL "")
		if(_address LESS _previous_end)
			message(FATAL_ERROR "Overlapping/out-of-order Flash units for ${STM32_DEVICE_UC}")
		elseif(_address GREATER _previous_end)
			set(STM32_FLASH_HAS_GAP ON)
		endif()
	endif()
	if(NOT _bank IN_LIST _seen_banks)
		set(STM32_FLASH_BANK${_bank}_ORIGIN "${_address}")
		list(APPEND _seen_banks "${_bank}")
	endif()
	set(STM32_FLASH_BANK${_bank}_END "${_end}")
	set(_previous_end "${_end}")
	list(APPEND STM32_FLASH_SECTORS "${_address}" "${_size}")
endwhile()
message(STATUS "Flash mode: ${STM32_FLASH_BANK_MODE} (supported: ${_bank_modes})")

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
# download STM32 headers (CMSIS system_stm32*.c/.h are not used by this runtime)
# ----------------------------------------------------------------------------

download_one(
	"${STM32_SERIES_LC}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/${STM32_SERIES_LC}.h")

download_one(
	"system_${STM32_SERIES_LC}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/system_${STM32_SERIES_LC}.h")

# system_*.h is required by the ST device headers. The vendor system_*.c,
# SystemInit and global SystemCoreClock implementation are intentionally unused.

download_one(
	"${STM32_NAME}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/${STM32_NAME}.h")

file(STRINGS "${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include/${STM32_SERIES_LC}.h"
	_selector_lines REGEX "${c_target}")
if(NOT _selector_lines)
	message(FATAL_ERROR "CMSIS header does not recognize selector ${c_target} for ${STM32_DEVICE_UC}")
endif()

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
