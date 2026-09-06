# ============================================================================
# functions.cmake — helpers used by cmsis-download.cmake
# ============================================================================
#
# Two groups of functions, split by comment banners below:
#
#   1. FETCH / CACHE PRIMITIVES  — pull per-device files from STM32-base_files
#      (download_one) and recover cleanly from a chip switch
#      (stm32_clean_build_dir).
#
#   2. GENERATORS  — turn those raw downloaded files into ready-to-use C++
#      headers via configure_file(... @ONLY): flash_config.h (sector map) and
#      irq_registry_config.h (IRQ dispatch stubs).
#
# cmsis-download.cmake is the file that actually orders the downloads and calls
# the generators in the right sequence — see it for the per-device flow, and
# ARCHITECTURE.md §04.4 for why the generated output is meant to be committed
# (vendored) rather than gitignored.
# ============================================================================


# ############################################################################
# 1. FETCH / CACHE PRIMITIVES
# ############################################################################

# ---------------------------------------------------------------------------
# download_one(FILE_NAME BASE_DIR URL_DIR)
#
#   FILE_NAME — destination file name only, no path (e.g. "stm32f446xx.h")
#   BASE_DIR  — destination directory, created if missing
#   URL_DIR   — the file's path inside the STM32-base_files repo, e.g.
#               "Device/STM32F4xx/Include/stm32f446xx.h"
#
# Fetches BASE_DIR/FILE_NAME from STM32-base_files if it isn't already there.
#
# "Already there and non-empty" always wins and is never re-downloaded — this
# is deliberate, not just an optimisation. On the final/consuming project the
# whole download destination is meant to be committed to git (vendored, not
# gitignored — see ARCHITECTURE.md §04.4), so "already there" normally means
# "vendored by an earlier configure", not "stale leftover". The one thing
# that should force a re-fetch — switching DEVICE — is handled by the caller
# deleting the whole download destination up front (see the device-change
# check in cmsis-download.cmake), not by this function guessing staleness on
# a per-file basis.
# ---------------------------------------------------------------------------
function(download_one FILE_NAME BASE_DIR URL_DIR)
	set(DEST "${BASE_DIR}/${FILE_NAME}")
	set(URL  "https://raw.githubusercontent.com/varvar6666/STM32-base_files/refs/heads/master/${URL_DIR}")

	message(STATUS "Downloading file: ${FILE_NAME}")

	# Skip re-downloading a file that's already vendored.
	if(EXISTS "${DEST}")
		file(SIZE "${DEST}" SZ)
		if(SZ GREATER 0)
			message(STATUS "File already downloaded: ${DEST}")
			return()
		endif()
	endif()

	file(MAKE_DIRECTORY "${BASE_DIR}")

	file(DOWNLOAD
		"${URL}"
		"${DEST}"
		STATUS RES
		TLS_VERIFY ON
	)

	list(GET RES 0 CODE)
	list(GET RES 1 MSG)

	if(NOT CODE EQUAL 0)
		file(REMOVE "${DEST}")
		message(FATAL_ERROR "Download failed: ${URL}\n${MSG}")
	endif()

	# A 0-byte file usually means a 404 that file(DOWNLOAD) didn't treat as a
	# hard failure (e.g. a redirect to an HTML error page) — catch it here
	# rather than silently vendoring an empty header.
	file(SIZE "${DEST}" SZ)
	if(SZ EQUAL 0)
		file(REMOVE "${DEST}")
		message(FATAL_ERROR "Downloaded file is empty: ${URL}")
	endif()

	message(STATUS "Download complete! File: ${DEST}")
endfunction()

# ---------------------------------------------------------------------------
# stm32_clean_build_dir()
#
# Wipes everything in the current build directory except CMakeCache.txt and
# CMakeFiles/. Called when DEVICE changes mid-project (see
# cmsis-download.cmake), so the next build can't mix object files compiled
# for the old chip with headers/linker scripts generated for the new one.
#
# CMakeCache.txt and CMakeFiles/ are kept, not because something later reuses
# them, but because this function runs *during* the very configure pass that
# owns them — deleting them out from under a configure that's still in
# progress would break this run, not just leave stale files behind.
# ---------------------------------------------------------------------------
function(stm32_clean_build_dir)
	message(STATUS "Cleaning build directory (except CMakeCache.txt)")

	file(GLOB BUILD_FILES
		"${CMAKE_BINARY_DIR}/*"
	)

	foreach(item IN LISTS BUILD_FILES)
		get_filename_component(name "${item}" NAME)

		if(NOT name STREQUAL "CMakeCache.txt"
		AND NOT name STREQUAL "CMakeFiles")
		file(REMOVE_RECURSE "${item}")
		endif()
	endforeach()
endfunction()


# ############################################################################
# 2. GENERATORS
# ############################################################################
#
#   stm32_generate_flash_config()  ->  Device/Include/flash_config.h
#       flash_sectors[] : one {address, size} entry per erase sector/page of
#       the selected chip's flash. This is what a flash driver (or the
#       bootloader) erases and writes by — it must never be guessed by hand.
#
#   stm32_generate_irq_handlers()  ->  Device/Include/irq_registry_config.h
#       one `extern "C" void XXX_IRQHandler()` stub per peripheral vector in
#       the downloaded vector_<device>.c, each forwarding to
#       IRQ_Registry::Dispatch(XXX_IRQn) — see STM32_Drivers_CPP's
#       IRQ_Registry.md for the runtime side that consumes this.
#
# Both run configure_file(... @ONLY) against a downloaded .h.in template.

# ---------------------------------------------------------------------------
# k_to_int(K_STR OUT)
#
# "128K" -> 128 (strips the trailing "K" used throughout the *-map.cmake
# flash/RAM tables, so the result can be fed to math()).
# ---------------------------------------------------------------------------
function(k_to_int K_STR OUT)
	string(REPLACE "K" "" _K "${K_STR}")
	set(${OUT} ${_K} PARENT_SCOPE)
endfunction()

# Uniform-page families: every flash page is the same size (in bytes), so a
# device's sector list can be derived purely from PAGE_SIZE + total flash
# size — no per-density table needed. Families *not* listed here are assumed
# to have a real sector map instead: see ${SERIES}_SECTOR_MAP inside the
# downloaded cmake/STM32<family>-map.cmake (F1/F2/F4/F7/G4/H7 all define one;
# G0/C0 don't, because they don't need to).
set(STM32G0_PAGE_SIZE 2048)
set(STM32C0_PAGE_SIZE 2048)

# ---------------------------------------------------------------------------
# stm32_generate_flash_config(SERIES FLASH_STR DEVICE_NAME TEMPLATE OUT_FILE)
#
# Two modes, selected automatically:
#
# 1) Sector-map mode  — ${SERIES}_SECTOR_MAP is defined.
#    Looks up FLASH_KB in the map to get single-bank sector count.
#    If STM32_DUAL_BANK is ON, count is doubled.
#    Map format: FLASH_KB  SECTOR_COUNT  (flat list, 2 fields per entry)
#
# 2) Uniform-page mode — ${SERIES}_PAGE_SIZE is defined (bytes).
#    All pages are equal; count = FLASH_KB * 1024 / PAGE_SIZE.
#    Generates FLASH_CFG_SECTORS_LIST — a list of {address, size} entries
#    for use in the flash_sectors[] array inside the .h.in template.
#
# TEMPLATE — path to the downloaded .h.in file.
# ---------------------------------------------------------------------------
function(stm32_generate_flash_config SERIES FLASH_STR DEVICE_NAME TEMPLATE OUT_FILE)

	# Strip the trailing "K" from flash size strings like "128K" -> "128"
	k_to_int("${FLASH_STR}" _kb)

	# Resolve the two possible data sources for this family.
	# Both are looked up by variable-variable indirection: if SERIES="STM32G0",
	# then ${STM32G0_SECTOR_MAP} and ${STM32G0_PAGE_SIZE} are read.
	set(_map     "${${SERIES}_SECTOR_MAP}")
	set(_page_sz "${${SERIES}_PAGE_SIZE}")

	# Always initialize to empty so the @FLASH_CFG_SECTORS_LIST@ placeholder
	# in the template expands to an empty string for sector-map families
	# whose templates do not use this variable.
	set(FLASH_CFG_SECTORS_LIST "")

	if(_map)
		# --- Sector-map path --------------------------------------------------
		# Used by families with heterogeneous sector sizes (F1, F2, F4, F7 …).
		# The map is a flat CMake list of pairs:  FLASH_KB  SECTOR_COUNT  …
		# e.g.  512 8  1024 12  2048 24
		# Find the index of the matching flash size entry.
		list(FIND _map "${_kb}" _idx)
		if(_idx LESS 0)
			message(FATAL_ERROR
				"stm32_generate_flash_config: no entry for ${_kb}K in ${SERIES}_SECTOR_MAP")
		endif()

		# The sector count immediately follows the flash-size entry in the list.
		math(EXPR _i1 "${_idx} + 1")
		list(GET _map ${_i1} FLASH_CFG_COUNT)

		# Dual-bank devices expose twice as many logical sectors.
		if(STM32_DUAL_BANK)
			math(EXPR FLASH_CFG_COUNT "${FLASH_CFG_COUNT} * 2")
		endif()

		set(_mode "sectors")

	elseif(_page_sz)
		# --- Uniform-page path ------------------------------------------------
		# Used by families where all flash pages have the same size (G0, C0 …).
		# Total page count = flash size in bytes / page size in bytes.
		math(EXPR FLASH_CFG_COUNT "${_kb} * 1024 / ${_page_sz}")

		# Build the flash_sectors[] initializer list that goes into the template
		# via @FLASH_CFG_SECTORS_LIST@.  Each entry is one {address, size} line.
		# Addresses are calculated as: STM32 flash base (0x08000000) + i * page_size.
		# OUTPUT_FORMAT HEXADECIMAL makes math() emit a 0x-prefixed hex literal
		# instead of a decimal integer (requires CMake ≥ 3.13).
		math(EXPR _last "${FLASH_CFG_COUNT} - 1")
		foreach(_i RANGE 0 ${_last})
			math(EXPR _addr "0x08000000 + ${_i} * ${_page_sz}" OUTPUT_FORMAT HEXADECIMAL)
			string(APPEND FLASH_CFG_SECTORS_LIST
				"    { ${_addr}UL, ${_page_sz}UL }, // Sector ${_i}\n")
		endforeach()

		set(_mode "pages (${_page_sz} B each)")

	else()
		message(FATAL_ERROR
			"stm32_generate_flash_config: neither ${SERIES}_SECTOR_MAP "
			"nor ${SERIES}_PAGE_SIZE is defined")
	endif()

	# Variables exposed to configure_file — they replace @PLACEHOLDER@ tokens
	# inside the .h.in template:
	#   @FLASH_CFG_DEVICE@      — MCU name string  (e.g. "STM32G030C6")
	#   @FLASH_CFG_FLASH_STR@   — flash size string (e.g. "32K")
	#   @FLASH_CFG_COUNT@       — total sector / page count
	#   @FLASH_CFG_SECTORS_LIST@— pre-built initializer lines (uniform-page only)
	set(FLASH_CFG_DEVICE    "${DEVICE_NAME}")
	set(FLASH_CFG_FLASH_STR "${FLASH_STR}")

	# Substitute all @VAR@ tokens in the template and write the output header.
	# @ONLY prevents CMake from also expanding ${VAR} style references that may
	# appear in C++ comments or string literals inside the template.
	configure_file("${TEMPLATE}" "${OUT_FILE}" @ONLY)

	message(STATUS
		"Flash config generated: ${OUT_FILE}  (${FLASH_CFG_COUNT} ${_mode}, dual_bank=${STM32_DUAL_BANK})")
endfunction()

# ---------------------------------------------------------------------------
# stm32_generate_irq_handlers(VECTOR_FILE TEMPLATE OUT_FILE)
#
# Parses the downloaded vector table and generates one header with:
#   - IRQ_TABLE_SIZE  (total peripheral slots, including reserved/gap entries)
#   - _irq_table[]    (dispatch table, built by the template itself)
#   - one extern "C" stub per *_IRQHandler found, calling
#     IRQ_Registry::Dispatch(XXX_IRQn)
#
# This only reads VECTOR_FILE — it's plain text scraping (`file(STRINGS ...
# REGEX ...)`), not a real C parser, so it depends on the vector_<device>.c
# files from STM32-base_files keeping their current formatting
# (`(uint32_t) XXX_IRQHandler,` per entry, `void XXX_IRQHandler(void)` for the
# weak declarations).
# ---------------------------------------------------------------------------
function(stm32_generate_irq_handlers VECTOR_FILE TEMPLATE OUT_FILE)

	# Total vector entries minus 16 ARM Cortex-M system exceptions = peripheral IRQ slots
	file(STRINGS "${VECTOR_FILE}" _all_entries REGEX "\\(uint32_t\\)")
	list(LENGTH _all_entries _total)
	math(EXPR IRQ_TABLE_SIZE "${_total} - 16")

	# Max handlers sharing one IRQ line — depends on MCU family
	if(STM32_SERIES_UC MATCHES "STM32G0")
		set(IRQ_MAX_SHARED 3)   # DMA1_Ch4_5_DMAMUX1_OVR: ch4 + ch5 + DMAMUX OVR
	elseif(STM32_SERIES_UC MATCHES "STM32(F4|F7)")
		set(IRQ_MAX_SHARED 2)   # timer pairs; DMA streams have own vectors
	else()
		set(IRQ_MAX_SHARED 2)   # safe default
	endif()

	file(STRINGS "${VECTOR_FILE}" _handler_lines
		 REGEX "void [A-Za-z0-9_]+_IRQHandler\\(void\\)")

	set(IRQ_HANDLERS_CODE "")

	foreach(_line ${_handler_lines})
		string(REGEX MATCH "void ([A-Za-z0-9_]+_IRQHandler)" _match "${_line}")

		if(CMAKE_MATCH_1)
			set(_handler_name "${CMAKE_MATCH_1}")
			string(REPLACE "_IRQHandler" "_IRQn" _irqn_name "${_handler_name}")

			string(APPEND IRQ_HANDLERS_CODE
				"extern \"C\" void ${_handler_name}() { IRQ_Registry::Dispatch(${_irqn_name}); }\n")
		endif()
	endforeach()

	configure_file("${TEMPLATE}" "${OUT_FILE}" @ONLY)

	message(STATUS "IRQ registry generated: ${OUT_FILE}  (IRQ_TABLE_SIZE=${IRQ_TABLE_SIZE}, IRQ_MAX_SHARED=${IRQ_MAX_SHARED})")
endfunction()
