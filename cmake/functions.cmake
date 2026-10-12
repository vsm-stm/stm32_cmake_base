# ============================================================================
# functions.cmake - all platform functions, definitions only, 0 side effects
# ============================================================================
# include()'d first from CMakeLists.txt. Does nothing on inclusion - just
# declares functions (in CMake they are global as soon as defined, so they
# are visible from cmsis-download.cmake and from STM32_Drivers_CPP/CMakeLists.txt
# alike).
#
#   stm32_read_config()      - project.json -> CFG_* variables (before project())
#   stm32_add_firmware()     - build one flashable image
#   download_one()           - pulls one file from STM32-base_files, skips it
#                              if it is already there
#   stm32_flash_window()     - sectors [START, END) -> origin address + length in bytes
#   k_to_int()               - "128K" -> 128
#   stm32_sync_device()      - chip change: wipe stale downloaded files + build,
#                              write the .device marker
# ============================================================================

# ---------------------------------------------------------------------------
# _stm32_json_array(CFG KEY OUT)   - internal: JSON array CFG[KEY] -> a list
#   Missing key / null / empty array -> empty list; other types are errors.
#   KEY may be a list of JSON path components (e.g. bootloader;extra_sources).
# ---------------------------------------------------------------------------
function(_stm32_json_array CFG KEY OUT)
	set(_list "")
	string(JSON _type ERROR_VARIABLE _e TYPE "${CFG}" ${KEY})
	if(_e OR _type STREQUAL "NULL")
		set(${OUT} "" PARENT_SCOPE)
		return()
	endif()
	if(NOT _type STREQUAL "ARRAY")
		message(FATAL_ERROR "${_stm32_config_path}: '${KEY}' must be an array of strings")
	endif()
	string(JSON _n LENGTH "${CFG}" ${KEY})
	if(_n GREATER 0)
		math(EXPR _last "${_n} - 1")
		foreach(_i RANGE ${_last})
			string(JSON _item_type TYPE "${CFG}" ${KEY} ${_i})
			if(NOT _item_type STREQUAL "STRING")
				message(FATAL_ERROR "${_stm32_config_path}: '${KEY}[${_i}]' must be a string")
			endif()
			string(JSON _item GET "${CFG}" ${KEY} ${_i})
			if(_item STREQUAL "" OR _item MATCHES ";")
				message(FATAL_ERROR "${_stm32_config_path}: '${KEY}[${_i}]' must be nonempty and contain no semicolon")
			endif()
			list(APPEND _list "${_item}")
		endforeach()
	endif()
	set(${OUT} "${_list}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# _stm32_load_json(PATH OUT)   - internal: file -> a JSON string for string(JSON)
#   Whole-line comments (first non-space character is //) are stripped:
#   string(JSON) only understands strict JSON. Trailing comments after a
#   value are not supported, and // inside string values (URLs) is left alone.
# ---------------------------------------------------------------------------
function(_stm32_load_json PATH OUT)
	if(NOT EXISTS "${PATH}")
		message(FATAL_ERROR "no such file ${PATH}")
	endif()
	file(READ "${PATH}" _j)
	# JSON files are inputs just like included CMake files.
	set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PATH}")
	string(REGEX REPLACE "(^|\n)[ \t]*//[^\n]*" "\\1" _j "${_j}")
	set(${OUT} "${_j}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# stm32_read_config(PATH PREFIX)
#
# Reads project.json and spreads it into ${PREFIX}_* variables (CFG_* for the
# project, BL_* for the bootloader) in the caller's scope. Called BEFORE
# project() - some values (name/version) are needed by project() itself.
#
#   CFG_name CFG_version CFG_device     - required, FATAL_ERROR otherwise
#   CFG_heap CFG_stack                  - default to 0x200 / 0x400
#   CFG_sources CFG_include_dirs        - lists (may be empty)
#   CFG_use_drivers                     - ON/OFF (see "drivers" below)
#   CFG_drivers                         - list of optional modules
#   CFG_app_start_sector                - "" or N; bootloader project only
#                                         (top-level app_start_sector key: image [0, N))
#   CFG_use_bootloader CFG_bootloader_{app_start_sector,repo,tag,extra_sources}
#                                       - the "bootloader" section (see below)
#
# "bootloader" in the application's project.json: null / key absent - no
#   bootloader, firmware starts at the beginning of flash; an object
#   {"app_start_sector": N, "repo": "<git url>", "tag": "<tag>",
#   "extra_sources": [...]} - bootloader at the start of flash, application
#   starts at sector N (CFG_app_start_sector = N). The bootloader is wired up
#   the same way as drivers: cloned into Bootloader/, its files come from its
#   own project.json, its CMakeLists.txt is not used. The bootloader's own
#   project.json sets the same N through its own top-level "app_start_sector" key.
#
#   "extra_sources" (optional) - files of THIS project (paths relative to its
#   own project.json) that get added to the bootloader image build. The
#   stm32-bootloader repository is a small library (image check, jump,
#   update flag), with its own main(). The project provides bl_stay() and
#   whatever transport/hardware code that function needs.
#
# "drivers" in project.json:
#   key absent / null / false  -> drivers are not built at all (CFG_use_drivers OFF)
#   true                      -> core drivers only (system/rcc/gpio/flash/irq)
#   []                        -> same, core only
#   ["UART", "SPI", ...]      -> core + listed modules
#
# All config validation happens here, in one pass. The format is data (JSON),
# not code: there is no way to slip extra logic into the config by mistake.
# Whole-line comments starting with // are allowed (as in JSONC).
# ---------------------------------------------------------------------------
function(stm32_read_config PATH PREFIX)
	get_filename_component(PATH "${PATH}" ABSOLUTE)
	set(_stm32_config_path "${PATH}")
	_stm32_load_json("${PATH}" _cfg)
	string(JSON _root_type ERROR_VARIABLE _json_error TYPE "${_cfg}")
	if(_json_error OR NOT _root_type STREQUAL "OBJECT")
		message(FATAL_ERROR "${PATH}: configuration must be a JSON object (${_json_error})")
	endif()

	# --- required string keys ---
	foreach(_k name version device)
		string(JSON _t ERROR_VARIABLE _e TYPE "${_cfg}" ${_k})
		if(_e OR NOT _t STREQUAL "STRING")
			message(FATAL_ERROR "${PATH}: '${_k}' must be a nonempty string")
		endif()
		string(JSON _v GET "${_cfg}" ${_k})
		if(_v STREQUAL "")
			message(FATAL_ERROR "${PATH}: '${_k}' must be a nonempty string")
		endif()
		set(_${_k} "${_v}")
		set(${PREFIX}_${_k} "${_v}" PARENT_SCOPE)
	endforeach()
	if(NOT _name MATCHES "^[A-Za-z_][A-Za-z0-9_.-]*$")
		message(FATAL_ERROR "${PATH}: 'name' is not a valid firmware target name")
	endif()
	if(_name STREQUAL "stm32_platform" OR _name STREQUAL "stm32_drivers")
		message(FATAL_ERROR "${PATH}: 'name' conflicts with a platform target")
	endif()
	if(NOT _version MATCHES "^[0-9]+(\\.[0-9]+)?(\\.[0-9]+)?(\\.[0-9]+)?$")
		message(FATAL_ERROR "${PATH}: 'version' must have one to four numeric components")
	endif()

	# --- heap / stack with defaults ---
	foreach(_k heap stack)
		string(JSON _t ERROR_VARIABLE _e TYPE "${_cfg}" ${_k})
		if(_e OR _t STREQUAL "NULL")
			if(_k STREQUAL "heap")
				set(_v "0x200")
			else()
				set(_v "0x400")
			endif()
		elseif(_t STREQUAL "STRING" OR _t STREQUAL "NUMBER")
			string(JSON _v GET "${_cfg}" ${_k})
		else()
			message(FATAL_ERROR "${PATH}: '${_k}' must be an unsigned integer")
		endif()
		if(NOT _v MATCHES "^(0[xX][0-9A-Fa-f]+|[0-9]+)$")
			message(FATAL_ERROR "${PATH}: '${_k}' must be an unsigned integer")
		endif()
		math(EXPR _bytes "${_v}")
		if(_bytes LESS 0 OR _bytes GREATER 4294967295)
			message(FATAL_ERROR "${PATH}: '${_k}' is outside the 32-bit size range")
		endif()
		if(_k STREQUAL "stack" AND _bytes EQUAL 0)
			message(FATAL_ERROR "${PATH}: 'stack' must be greater than zero")
		endif()
		set(${PREFIX}_${_k} "${_bytes}" PARENT_SCOPE)
	endforeach()

	# --- arrays -> lists ---
	_stm32_json_array("${_cfg}" sources      _sources)
	_stm32_json_array("${_cfg}" include_dirs _include_dirs)

	# --- drivers: tri-state (see the function header) ---
	string(JSON _dt ERROR_VARIABLE _e TYPE "${_cfg}" drivers)
	set(${PREFIX}_drivers "" PARENT_SCOPE)
	if(_e OR _dt STREQUAL "NULL")
		set(${PREFIX}_use_drivers OFF PARENT_SCOPE)
	elseif(_dt STREQUAL "BOOLEAN")
		string(JSON _dv GET "${_cfg}" drivers)
		set(${PREFIX}_use_drivers "${_dv}" PARENT_SCOPE)
	elseif(_dt STREQUAL "ARRAY")
		set(${PREFIX}_use_drivers ON PARENT_SCOPE)
		_stm32_json_array("${_cfg}" drivers _list)
		set(${PREFIX}_drivers "${_list}" PARENT_SCOPE)
	else()
		message(FATAL_ERROR "${PATH}: 'drivers' must be an array, true/false, or null")
	endif()

	# --- driver_sources: files built only alongside drivers (bootloader) ---
	_stm32_json_array("${_cfg}" driver_sources _driver_sources)

	# --- paths in the config are relative to this project.json's directory;
	#     everything handed out is absolute ---
	get_filename_component(_root "${PATH}" DIRECTORY)
	foreach(_l _sources _include_dirs _driver_sources)
		set(_abs "")
		foreach(_r ${${_l}})
			get_filename_component(_r "${_r}" ABSOLUTE BASE_DIR "${_root}")
			list(APPEND _abs "${_r}")
		endforeach()
		set(${_l} "${_abs}")
	endforeach()
	set(${PREFIX}_driver_sources "${_driver_sources}" PARENT_SCOPE)
	set(${PREFIX}_sources      "${_sources}"      PARENT_SCOPE)
	set(${PREFIX}_include_dirs "${_include_dirs}" PARENT_SCOPE)

	# --- top-level app_start_sector: bootloader project only ---
	set(${PREFIX}_app_start_sector "" PARENT_SCOPE)
	string(JSON _t ERROR_VARIABLE _e TYPE "${_cfg}" app_start_sector)
	if(NOT _e AND NOT _t STREQUAL "NULL")
		string(JSON _v GET "${_cfg}" app_start_sector)
		if(NOT _t STREQUAL "NUMBER" OR NOT _v MATCHES "^[0-9]+$" OR _v LESS 1)
			message(FATAL_ERROR "${PATH}: 'app_start_sector' must be an integer >= 1")
		endif()
		set(${PREFIX}_app_start_sector "${_v}" PARENT_SCOPE)
	endif()

	# --- bootloader: null / key absent -> no bootloader; otherwise an object ---
	set(${PREFIX}_use_bootloader OFF PARENT_SCOPE)
	set(${PREFIX}_bootloader_repo "" PARENT_SCOPE)
	set(${PREFIX}_bootloader_tag  "" PARENT_SCOPE)
	set(${PREFIX}_bootloader_extra_sources "" PARENT_SCOPE)
	string(JSON _bt ERROR_VARIABLE _e TYPE "${_cfg}" bootloader)
	if(NOT _e AND _bt STREQUAL "OBJECT")
		if(_name STREQUAL "bootloader")
			message(FATAL_ERROR "${PATH}: application name 'bootloader' conflicts with the bootloader target")
		endif()
		string(JSON _bs_type ERROR_VARIABLE _e TYPE "${_cfg}" bootloader app_start_sector)
		string(JSON _bs ERROR_VARIABLE _e GET "${_cfg}" bootloader app_start_sector)
		if(_e OR NOT _bs_type STREQUAL "NUMBER" OR NOT "${_bs}" MATCHES "^[0-9]+$" OR _bs LESS 1)
			message(FATAL_ERROR "${PATH}: 'bootloader.app_start_sector' must be an integer >= 1")
		endif()
		string(JSON _br ERROR_VARIABLE _e GET "${_cfg}" bootloader repo)
		if(_e)
			set(_br "https://github.com/vsm-stm/stm32-bootloader.git")
		endif()
		string(JSON _bg ERROR_VARIABLE _e GET "${_cfg}" bootloader tag)
		if(_e)
			set(_bg "main")
		endif()
		foreach(_key repo tag)
			string(JSON _type ERROR_VARIABLE _err TYPE "${_cfg}" bootloader ${_key})
			if(NOT _err)
				string(JSON _value GET "${_cfg}" bootloader ${_key})
				if(NOT _type STREQUAL "STRING" OR _value STREQUAL "")
					message(FATAL_ERROR "${PATH}: 'bootloader.${_key}' must be a nonempty string")
				endif()
			endif()
		endforeach()
		set(${PREFIX}_use_bootloader ON PARENT_SCOPE)
		set(${PREFIX}_app_start_sector "${_bs}" PARENT_SCOPE)
		set(${PREFIX}_bootloader_repo "${_br}" PARENT_SCOPE)
		set(${PREFIX}_bootloader_tag  "${_bg}" PARENT_SCOPE)

		# Empty/missing extra_sources contributes no files. main() is in the
		# dependency; these files normally implement bl_stay().
		_stm32_json_array("${_cfg}" "bootloader;extra_sources" _extras)
		set(_bps "")
		foreach(_r IN LISTS _extras)
			get_filename_component(_r "${_r}" ABSOLUTE BASE_DIR "${_root}")
			list(APPEND _bps "${_r}")
		endforeach()
		set(${PREFIX}_bootloader_extra_sources "${_bps}" PARENT_SCOPE)
	elseif(NOT _e AND NOT _bt STREQUAL "NULL")
		message(FATAL_ERROR "${PATH}: 'bootloader' must be an object or null")
	endif()
endfunction()

# ---------------------------------------------------------------------------
# download_one(FILE_NAME BASE_DIR URL_DIR [OPTIONAL] [REPO_URL_BASE <url>])
#
#   FILE_NAME - just the destination file name, no path (e.g. "stm32f446xx.h")
#   BASE_DIR  - destination directory, created if missing
#   URL_DIR   - the file's path inside the repository, e.g.
#               "Device/STM32F4xx/Include/stm32f446xx.h"
#   REPO_URL_BASE - where to download from; defaults to the raw content of
#               STM32-base_files (master branch). A different repository
#               (e.g. a single file from STM32_Drivers_CPP by tag - done by
#               stm32-bootloader in its own CMakeLists.txt, not the platform)
#               is passed through this argument.
#
# Downloads BASE_DIR/FILE_NAME if it is not already there. OPTIONAL - the
# file is not required (e.g. an SVD, needed only by the debugger): failure
# produces a warning, not a configuration error.
#
# In remote mode, "already there and non-empty" wins and is not re-downloaded - this
# is deliberate, not just an optimization. In the finished project the whole
# download directory is committed to git (vendored, not .gitignore'd), so
# "already there" usually means "placed by a previous configure", not "stale
# junk". The only thing that should force a re-download - a DEVICE change -
# is handled by the caller: MCU/runtime format changes wipe the download directory
# (see stm32_sync_device()), rather than this function guessing at each
# file's staleness individually. STM32_BASE_FILES_DIR instead tracks a local
# checkout with configure_file(COPYONLY) and configuration dependencies.
# ---------------------------------------------------------------------------
function(download_one FILE_NAME BASE_DIR URL_DIR)
	cmake_parse_arguments(DL "OPTIONAL" "REPO_URL_BASE" "" ${ARGN})
	set(_optional ${DL_OPTIONAL})
	set(_from_base_files OFF)
	if(NOT DL_REPO_URL_BASE)
		set(_from_base_files ON)
		set(DL_REPO_URL_BASE "https://raw.githubusercontent.com/vsm-stm/STM32-base_files/refs/heads/master/")
	endif()

	set(DEST "${BASE_DIR}/${FILE_NAME}")
	set(URL  "${DL_REPO_URL_BASE}${URL_DIR}")

	message(STATUS "Downloading file: ${FILE_NAME}")

	file(MAKE_DIRECTORY "${BASE_DIR}")
	# Development/vendor override; explicit alternate repositories (e.g. CRC)
	# keep using their own REPO_URL_BASE. No network fallback for missing files.
	if(STM32_BASE_FILES_DIR AND _from_base_files)
		get_filename_component(_local_root "${STM32_BASE_FILES_DIR}" ABSOLUTE BASE_DIR "${CMAKE_SOURCE_DIR}")
		set(_local_file "${_local_root}/${URL_DIR}")
		if(EXISTS "${_local_file}")
			file(SIZE "${_local_file}" _size)
			if(_size GREATER 0)
				configure_file("${_local_file}" "${DEST}" COPYONLY)
				return()
			endif()
		endif()
		if(_optional)
			message(WARNING "Optional base file not available: ${_local_file}")
			return()
		endif()
		message(FATAL_ERROR "Missing/empty local base file: ${_local_file}")
	endif()
	# Remote files are vendored once; a local override tracks its source files.
	if(EXISTS "${DEST}")
		file(SIZE "${DEST}" SZ)
		if(SZ GREATER 0)
			message(STATUS "File already downloaded: ${DEST}")
			return()
		endif()
	endif()

	file(DOWNLOAD
		"${URL}"
		"${DEST}"
		STATUS RES
		TLS_VERIFY ON
		TIMEOUT 60
		INACTIVITY_TIMEOUT 15
	)

	list(GET RES 0 CODE)
	list(GET RES 1 MSG)

	if(NOT CODE EQUAL 0)
		file(REMOVE "${DEST}")
		if(_optional)
			message(WARNING "Optional file not available, skipped: ${URL}")
			return()
		endif()
		message(FATAL_ERROR "Download failed: ${URL}\n${MSG}")
	endif()

	# A 0-byte file is usually a 404 that file(DOWNLOAD) did not treat as a
	# hard error (e.g. a redirect to an HTML error page) - caught here
	# instead of silently leaving an empty header in place.
	file(SIZE "${DEST}" SZ)
	if(SZ EQUAL 0)
		file(REMOVE "${DEST}")
		message(FATAL_ERROR "Downloaded file is empty: ${URL}")
	endif()

	message(STATUS "Download complete! File: ${DEST}")
endfunction()

# ---------------------------------------------------------------------------
# k_to_int(K_STR OUT)
#
# "128K" -> 128 (strips the trailing "K" used throughout every *-map.cmake's
# flash/RAM tables, so the result can be fed into math()).
# ---------------------------------------------------------------------------
function(k_to_int K_STR OUT)
	string(REPLACE "K" "" _K "${K_STR}")
	set(${OUT} ${_K} PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# stm32_flash_window(START END OUT_ORIGIN OUT_LENGTH)
#
# The image's flash window: erase sectors [START, END) - START inclusive, END
# NOT inclusive (it is the sector number the NEXT image starts at).
#
#   START ""  -> 0                   (from the start of flash)
#   END   ""  -> chip's sector count (to the end of flash)
#
# OUT_ORIGIN <- absolute address of the start of sector START (e.g. 0x08010000)
# OUT_LENGTH <- bytes from there to the start of sector END (or to the end of flash)
#
# Reads STM32_FLASH_SECTORS (a list "addr;size;addr;size;...", resolved in
# cmsis-download.cmake from the downloaded map table). End of flash is the
# address plus the size of the last sector. Non-integer values, out-of-range
# sectors, and END <= START are configuration-time errors.
# ---------------------------------------------------------------------------
function(stm32_flash_window START END OUT_ORIGIN OUT_LENGTH)
	list(LENGTH STM32_FLASH_SECTORS _n)
	math(EXPR _count "${_n} / 2")

	if("${START}" STREQUAL "")
		set(START 0)
	endif()
	if("${END}" STREQUAL "")
		set(END ${_count})
	endif()

	foreach(_name START END)
		if(NOT "${${_name}}" MATCHES "^[0-9]+$")
			message(FATAL_ERROR
				"stm32_flash_window: ${_name} must be an integer >= 0, "
				"got '${${_name}}'")
		endif()
	endforeach()
	math(EXPR _last "${_count} - 1")
	if(START GREATER_EQUAL _count)
		message(FATAL_ERROR
			"stm32_flash_window: start_sector ${START} is out of range - the chip "
			"has ${_count} erase sectors (numbers 0..${_last})")
	endif()
	if(END GREATER _count OR NOT END GREATER START)
		message(FATAL_ERROR
			"stm32_flash_window: end_sector ${END} is invalid for start_sector "
			"${START} - need ${START} < end_sector <= ${_count} (end_sector is not "
			"part of the image; ${_count} = to the end of flash)")
	endif()

	# the list is flat: [addr0 size0 addr1 size1 ...], so address index = N*2
	math(EXPR _si "${START} * 2")
	list(GET STM32_FLASH_SECTORS ${_si} _origin)

	if(END EQUAL _count)
		list(GET STM32_FLASH_SECTORS -2 _last_a)   # address of the last sector
		list(GET STM32_FLASH_SECTORS -1 _last_s)   # size of the last sector
		math(EXPR _end_addr "${_last_a} + ${_last_s}")
	else()
		math(EXPR _ei "${END} * 2")
		list(GET STM32_FLASH_SECTORS ${_ei} _end_addr)
	endif()
	math(EXPR _len "${_end_addr} - ${_origin}")

	set(${OUT_ORIGIN} "${_origin}" PARENT_SCOPE)
	set(${OUT_LENGTH} "${_len}"    PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# stm32_sync_device(DEVICE)
#
# Keeps the downloaded files in sync with the chip from project.json.
# Everything related to a chip change lives here, in one place:
#   1. reads the cmsis-core/download_files/.device marker (which chip the
#      files were downloaded for);
#   2. if the chip changed (or the files are sitting there without a marker -
#      treated as foreign) - wipes cmsis-core/download_files/,
#      cmsis-core/drivers_gen/, and the build directory's contents except
#      CMakeCache.txt and CMakeFiles/;
#   3. writes the marker with the current chip.
#
# The marker sits next to the files, not in the CMake cache: what was
# downloaded lives in the project tree and survives a build/ wipe.
#
# CMakeCache.txt and CMakeFiles/ are kept not because anything reuses them,
# but because this function runs *during* the configure pass they belong to -
# deleting them out from under the pass in progress would break the current
# run.
# ---------------------------------------------------------------------------
function(stm32_sync_device DEVICE)
	stm32_validate_build_directory()
	set(_dl     "${CMAKE_SOURCE_DIR}/cmsis-core/download_files")
	set(_marker "${_dl}/.device")
	set(_format_marker "${_dl}/.platform-format")
	set(_format "")
	if(EXISTS "${_format_marker}")
		file(READ "${_format_marker}" _format)
		string(STRIP "${_format}" _format)
	endif()

	set(_old "")
	if(EXISTS "${_marker}")
		file(READ "${_marker}" _old)
		string(STRIP "${_old}" _old)
	endif()

	if(_old STREQUAL "" AND NOT EXISTS "${_dl}")
		message(STATUS "Initial STM32 configuration for device: ${DEVICE}")
	elseif(NOT _old STREQUAL DEVICE OR NOT _format STREQUAL "2")
		message(WARNING
			"STM32 device/platform format changed (runtime format ${_format} -> 2):
"
			"  old: ${_old}  (empty = no marker was present)
"
			"  new: ${DEVICE}
"
			"Cleaning downloaded STM32 files and build directory."
		)
		file(REMOVE_RECURSE "${_dl}" "${CMAKE_SOURCE_DIR}/cmsis-core/drivers_gen")

		file(GLOB _build_items "${CMAKE_BINARY_DIR}/*")
		foreach(_item IN LISTS _build_items)
			get_filename_component(_name "${_item}" NAME)
			if(NOT _name STREQUAL "CMakeCache.txt" AND NOT _name STREQUAL "CMakeFiles")
				file(REMOVE_RECURSE "${_item}")
			endif()
		endforeach()
	else()
		message(STATUS "STM32 device unchanged: ${DEVICE}")
	endif()

	file(MAKE_DIRECTORY "${_dl}")
	file(WRITE "${_marker}" "${DEVICE}
")
	file(WRITE "${_format_marker}" "2\n")
endfunction()

# Build/download/generated directories contain disposable artifacts only.
# In-source or ancestor builds would include the project's own source files.
function(stm32_validate_build_directory)
	file(REAL_PATH "${CMAKE_SOURCE_DIR}" _source)
	file(REAL_PATH "${CMAKE_BINARY_DIR}" _binary)
	if(CMAKE_HOST_WIN32)
		string(TOLOWER "${_source}" _source)
		string(TOLOWER "${_binary}" _binary)
	endif()
	cmake_path(IS_PREFIX _binary "${_source}" NORMALIZE _contains_source)
	if(_contains_source)
		message(FATAL_ERROR "Use a dedicated build directory outside the source root (for example build/debug). Build directories are cleaned on MCU changes.")
	endif()
endfunction()

# ---------------------------------------------------------------------------
# stm32_add_firmware(TARGET  SOURCES ...  [INCLUDE_DIRS ...]  [LINK ...]
#                           [START_SECTOR N] [END_SECTOR M])
#
# Builds one flashable image. Everything shared - cpu/fpu flags, libc,
# warnings, linker flags - comes from the stm32_platform target (created in
# CMakeLists.txt); optimization and debug info come from the preset
# (CMAKE_<LANG>_FLAGS_<CONFIG>). Only what is specific to each image lives
# here: flash window, linker script, exe, post-build.
#
# START_SECTOR - the erase-sector number to start at (from 0). Unset = 0.
# END_SECTOR   - the sector number the NEXT image starts at (not itself part
#   of this one). Unset = to the end of flash. The linker gets FLASH LENGTH
#   set strictly to this window, so an image that does not fit its sectors
#   is a link error (region FLASH overflowed), not a silent overlap with the
#   neighboring image.
#   Example: bootloader START 0 END 4, application START 4 (no END).
#
# Reads from the top-level scope: the stm32_platform target (CMakeLists.txt)
# and whatever cmsis-download.cmake sets - STM32_LINKER_TEMPLATE,
# STM32_STARTUP_SRCS, STM32_FLASH_SECTORS, HEAP_SIZE/STACK_SIZE,
# RAM_ORIGIN/RAM_LENGTH, and the family's MEMORY-region variables (substituted
# into the linker script template). Hence it is called from the same scope
# where cmsis-download.cmake has already run - from CMakeLists.txt.
# ---------------------------------------------------------------------------
function(stm32_add_firmware TARGET)
	cmake_parse_arguments(FW "" "START_SECTOR;END_SECTOR" "SOURCES;INCLUDE_DIRS;LINK" ${ARGN})

	# --- this image's flash window ---
	stm32_flash_window("${FW_START_SECTOR}" "${FW_END_SECTOR}" FLASH_ORIGIN FLASH_LENGTH)

	# the image window's bounds, into the sources (the bootloader needs the
	# address the NEXT image - the application - starts at: STM32_IMAGE_FLASH_END)
	math(EXPR _img_end "${FLASH_ORIGIN} + ${FLASH_LENGTH}" OUTPUT_FORMAT HEXADECIMAL)

	# --- linker script for this target ---
	set(_ld "${CMAKE_CURRENT_BINARY_DIR}/${TARGET}.ld")
	configure_file("${STM32_LINKER_TEMPLATE}" "${_ld}" @ONLY)

	# --- executable ---
	add_executable(${TARGET})
	target_sources(${TARGET} PRIVATE ${FW_SOURCES} ${STM32_STARTUP_SRCS})
	target_include_directories(${TARGET} PRIVATE ${FW_INCLUDE_DIRS})
	target_link_libraries(${TARGET} PRIVATE stm32_platform ${FW_LINK})
	target_link_options(${TARGET} PRIVATE -T${_ld} -Wl,-Map=${TARGET}.map)
	set_property(TARGET ${TARGET} APPEND PROPERTY LINK_DEPENDS "${_ld}")
	target_compile_definitions(${TARGET} PRIVATE
		STM32_IMAGE_FLASH_ORIGIN=${FLASH_ORIGIN}U
		STM32_IMAGE_FLASH_END=${_img_end}U)

	# --- post-build: size + .hex / .bin / .dis ---
	add_custom_command(TARGET ${TARGET} POST_BUILD
		COMMAND ${CMAKE_SIZE}    $<TARGET_FILE:${TARGET}>
		COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:${TARGET}> ${TARGET}.hex
		COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${TARGET}> ${TARGET}.bin
		COMMAND ${CMAKE_OBJDUMP} -d -S     $<TARGET_FILE:${TARGET}> > ${TARGET}.dis
	)

	message(STATUS "firmware '${TARGET}': FLASH ${FLASH_ORIGIN} + ${FLASH_LENGTH} B")
endfunction()
