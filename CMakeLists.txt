cmake_minimum_required(VERSION 3.24)

# ─── project config: project.json -> CFG_* ──────────────────────────────────
include(${CMAKE_SOURCE_DIR}/cmake/functions.cmake)
stm32_validate_build_directory()
stm32_read_config(${CMAKE_SOURCE_DIR}/project.json CFG)

# ─── toolchain (only "which compiler"; flags live in stm32_platform/presets) ─
if(NOT CMAKE_TOOLCHAIN_FILE)
	set(CMAKE_TOOLCHAIN_FILE "${CMAKE_SOURCE_DIR}/cmake/toolchain.cmake"
		CACHE FILEPATH "STM32 arm-none-eabi toolchain" FORCE)
endif()

project(${CFG_name} VERSION ${CFG_version} LANGUAGES C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

message(STATUS "Project: ${CFG_name}  Device: ${CFG_device}  Build: ${CMAKE_BUILD_TYPE}")

# ─── download CMSIS/startup/vectors + parse CFG_device ──────────────────────
#     provides main_cpu_PARAMS, STM32_*, STM32_LINKER_TEMPLATE, STM32_STARTUP_SRCS,
#     STM32_FLASH_SECTORS, HEAP_SIZE/STACK_SIZE, RAM_* ...
include(${CMAKE_SOURCE_DIR}/cmake/cmsis-download.cmake)

# ─── stm32_platform: a single INTERFACE target with every flag ─────────────
#     linked by both the firmware (stm32_add_firmware) and stm32_drivers -
#     neither needs to know about cmsis-core/ or the chip's cpu/fpu.

# Only flags that do not depend on the configuration live here. Optimization
# and debug info (-Og/-O0/-Os, -g*, NDEBUG) come from CMakePresets.json via
# CMAKE_<LANG>_FLAGS_<CONFIG> - one preset per build variant.
if(NOT CMAKE_BUILD_TYPE)
	message(WARNING "CMAKE_BUILD_TYPE is not set - no optimization. Use a preset: cmake --preset debug|release|...")
endif()

add_library(stm32_platform INTERFACE)

target_include_directories(stm32_platform INTERFACE
	${CMAKE_SOURCE_DIR}/cmsis-core/Include
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include
)
target_compile_definitions(stm32_platform INTERFACE
	${c_target}          # STM32F446xx - CMSIS includes registers under this name
	${STM32_DEVICE_UC}   # STM32F446RE
	${STM32_CORE}        # STM32F4
	"STM32_DEVICE_HEADER=\"${STM32_SERIES_LC}.h\""   # for #include STM32_DEVICE_HEADER in code without drivers
	$<$<CONFIG:Debug>:DEBUG>
)
target_compile_options(stm32_platform INTERFACE
	-mthumb ${main_cpu_PARAMS}                     # cpu/fpu from *-map.cmake
	-fdata-sections -ffunction-sections            # for -Wl,--gc-sections
	$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions -fno-rtti -fno-threadsafe-statics>
	-Wall -Wextra -Wpedantic -Wno-unused-parameter
)
target_link_options(stm32_platform INTERFACE
	-mthumb ${main_cpu_PARAMS}
	-Wl,--gc-sections
	--specs=nano.specs --specs=nosys.specs
	-Wl,--start-group -lc -lm -lstdc++ -lsupc++ -Wl,--end-group
	-Wl,-z,max-page-size=8              # pack sections tightly by address
	-Wl,--wrap=__register_exitproc      # no OS, so no C++ static destructors needed
	-Wl,--no-warn-rwx-segments          # linker scripts do not separate code/data into segments:
	                                     # without an MMU/MPU the permission bits in the ELF do
	                                     # nothing, and splitting into segments breaks on empty
	                                     # .data/.ccmram
	-Wl,--print-memory-usage
)

# ─── drivers ─────────────────────────────────────────────────────────────────
#     "drivers" in project.json: key absent / null / false = do not build at all;
#     true or [] = core only; ["UART", ...] = core + modules.
#     The first configure clones into Drivers/, after that add_subdirectory as-is.
set(_fw_link "")
if(CFG_use_drivers)
	set(STM32_DRIVERS_REQUESTED "${CFG_drivers}" CACHE STRING
		"Optional driver modules" FORCE)
	if(EXISTS "${CMAKE_SOURCE_DIR}/Drivers/CMakeLists.txt")
		add_subdirectory(Drivers "${CMAKE_BINARY_DIR}/_deps/drivers-build")
	else()
		include(FetchContent)
		FetchContent_Declare(Drivers
			SOURCE_DIR     ${CMAKE_SOURCE_DIR}/Drivers
			GIT_REPOSITORY https://github.com/vsm-stm/STM32_Drivers_CPP.git
			GIT_TAG        v2.1)
		FetchContent_MakeAvailable(Drivers)
	endif()
	set(_fw_link stm32_drivers)
else()
	message(STATUS "Drivers: disabled (\"drivers\" = null/false/absent in project.json)")
endif()

# ─── bootloader (same pattern as drivers) ────────────────────────────────────
#     "bootloader" in project.json: absent / null - no bootloader, firmware starts
#     at the beginning of flash; {"app_start_sector": N, "repo": ..., "tag": ...} -
#     bootloader at the start of flash, sectors [0, N), application starts at
#     sector N. Always pulled from a repository (git) into Bootloader/ - no
#     project-specific edits go there, they go through "bootloader"."extra_sources"
#     (see below). For local development of the bootloader itself - the usual
#     FetchContent override:
#       -DFETCHCONTENT_SOURCE_DIR_BOOTLOADER=<path to a working copy of stm32-bootloader>
#     Its CMakeLists.txt is NOT used: the file list comes from its project.json
#     (via the same stm32_read_config), this file drives the build.
if(CFG_use_bootloader)
	include(FetchContent)
	FetchContent_Declare(bootloader
		SOURCE_DIR     ${CMAKE_SOURCE_DIR}/Bootloader
		GIT_REPOSITORY ${CFG_bootloader_repo}
		GIT_TAG        ${CFG_bootloader_tag}
		GIT_SHALLOW    TRUE
		SOURCE_SUBDIR  _no_cmake_here_)   # clone only, its own CMakeLists is not run
	FetchContent_MakeAvailable(bootloader)
	message(STATUS "Bootloader: ${bootloader_SOURCE_DIR}")

	# read project.json from the ACTUAL directory (normally Bootloader/; with
	# FETCHCONTENT_SOURCE_DIR_BOOTLOADER - the override path, no cloning)
	stm32_read_config("${bootloader_SOURCE_DIR}/project.json" BL)
	set(_bl_sources ${BL_sources})
	if(CFG_use_drivers)
		list(APPEND _bl_sources ${BL_driver_sources})
	endif()
	# extra_sources supplies bl_stay() and its transport/hardware code.
	# The bootloader's own source list already supplies main().
	list(APPEND _bl_sources ${CFG_bootloader_extra_sources})
	stm32_add_firmware(bootloader
		SOURCES       ${_bl_sources}
		# this project's own include paths too: whatever extra_sources pulls in,
		# it gets the same headers as the ordinary application image
		INCLUDE_DIRS  ${BL_include_dirs};${CFG_include_dirs}
		LINK          ${_fw_link}
		START_SECTOR  0
		END_SECTOR    ${CFG_app_start_sector}
	)

	# The application gets the same bootloader include paths (typically
	# Bootloader/src) automatically - not just the bootloader itself. This way
	# files like bl_update_flag.h (the shared "update requested" flag, see
	# stm32-bootloader) are #include'd from a SINGLE file in the bootloader
	# repository on both sides, instead of being copy-pasted into the
	# application: the magic value and its handling live there only.
	list(APPEND CFG_include_dirs ${BL_include_dirs})
endif()

# ─── firmware image ──────────────────────────────────────────────────────────
#     flash window: no bootloader - the whole flash; with a bootloader - [N, end);
#     bootloader project itself (app_start_sector in its own project.json) - [0, N).
set(_sector "")
if(CFG_use_bootloader)
	set(_sector START_SECTOR ${CFG_app_start_sector})
elseif(NOT CFG_app_start_sector STREQUAL "")
	set(_sector START_SECTOR 0 END_SECTOR ${CFG_app_start_sector})
endif()

set(_sources ${CFG_sources})
if(CFG_use_drivers)
	list(APPEND _sources ${CFG_driver_sources})
endif()

stm32_add_firmware(${CFG_name}
	${_sector}
	SOURCES       ${_sources}
	INCLUDE_DIRS  ${CFG_include_dirs}
	LINK          ${_fw_link}
)
