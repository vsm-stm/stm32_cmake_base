cmake_minimum_required(VERSION 3.22)
################################## BASE SETUP ###############################################################
include("${CMAKE_CURRENT_SOURCE_DIR}/base-setup.cmake")

# Toolchain — registered as CMAKE_TOOLCHAIN_FILE (the official mechanism, not
# a bare include()) so it's cached, feeds try_compile()/ExternalProject_Add(),
# and shows up in IDE tooling. The `if(NOT ...)` guard means an explicit
# -DCMAKE_TOOLCHAIN_FILE=... or preset override still wins; otherwise this is
# what makes the project build with the right compiler even with no preset
# at all.
if(NOT CMAKE_TOOLCHAIN_FILE)
	set(CMAKE_TOOLCHAIN_FILE "${CMAKE_CURRENT_LIST_DIR}/cmake/gcc-arm-none-eabi.cmake"
		CACHE FILEPATH "STM32 arm-none-eabi toolchain" FORCE)
endif()

################################## PROJECT SETUP ###############################################################
project(${PROJECT_NAME}
	VERSION ${VER}
	DESCRIPTION "${DESC}"
	LANGUAGES C CXX ASM
)

# Общие стандарты (можно переопределять из cache/preset)
set(CMAKE_C_STANDARD 11 CACHE STRING "C standard")
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)

set(CMAKE_CXX_STANDARD 20 CACHE STRING "C++ standard")
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Полезно при работе с IDE и статанализаторами
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

message(STATUS "Project: ${PROJECT_NAME}")
message(STATUS "Device: ${DEVICE}")
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")

############################# MCU / CPU parameters + CMSIS ##################################
#donwnload cmsis
include("${CMAKE_CURRENT_LIST_DIR}/cmake/cmsis-download.cmake")

# Linker script
set(linker_script_SRC
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker/${STM32_DEVICE_LC}.ld
)
# Mandatory glue - same category as the linker script / startup / vectors,
# not user code: startup + vector table, and the newlib retarget stubs
# (sysmem.c = _sbrk/heap, syscalls.c = _write/_read/... ). Always compiled in.
list(APPEND sources_SRCS
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/vector_${STM32_NAME}.c
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/startup_common.c
	${CMAKE_SOURCE_DIR}/no_system_files/sysmem.c
	${CMAKE_SOURCE_DIR}/no_system_files/syscalls.c
)

# Include CMSIS / Device paths
list(APPEND include_DIRS
	${CMAKE_SOURCE_DIR}/cmsis-core/Include
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include
)

################################## TARGET DEFINITIONS ###############################################################
add_executable(${CMAKE_PROJECT_NAME})
target_sources(${CMAKE_PROJECT_NAME} PRIVATE ${sources_SRCS})
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${include_DIRS})

target_compile_definitions( ${CMAKE_PROJECT_NAME} PRIVATE
	${symbols_SYMB}
	${c_target}
	${STM32_DEVICE_UC}
	${STM32_CORE}
	${STM32_FLASH_def}
	$<$<COMPILE_LANGUAGE:C>: ${symbols_c_SYMB}>
	$<$<COMPILE_LANGUAGE:CXX>: ${symbols_cxx_SYMB}>
	$<$<COMPILE_LANGUAGE:ASM>: ${symbols_asm_SYMB}>
)

################################## COMPILER OPTIONS ################################################################ Compiler options
# Optimisation level for Debug builds. -Og is the default (debug-friendly but
# still optimised); the "debug-o0" preset drops it to -O0 for fully
# step-through debugging (every var live, no inlining/reordering).
set(STM32_DEBUG_OPT "-Og" CACHE STRING "Optimisation flag for Debug builds (-Og / -O0 / ...)")

target_compile_options(${CMAKE_PROJECT_NAME} PRIVATE
	-mthumb
	${main_cpu_PARAMS}
	${cpu_PARAMS}
	${compiler_OPTS}
	-Wall
	-Wextra
	-Wpedantic
	-Wno-unused-parameter
	# -Wno-volatile
	# -Wold-style-cast
	# -Wuseless-cast
	# -Wsuggest-override
	# $<$<COMPILE_LANGUAGE:ASM>:-x assembler-with-cpp -MMD -MP>
	$<$<CONFIG:Debug>:${STM32_DEBUG_OPT} -g3 -ggdb>
	$<$<CONFIG:Release>:-Os -g0>
)

################################## DRIVERS ###############################################################
# stm32_drivers (STM32_Drivers_CPP) lives inside the project at Drivers/.
# First configure clones it there; after that it's just add_subdirectory()'d
# as-is every configure (FetchContent must NOT re-sync it - vendored files
# are edited/committed in place). It reads STM32_DRIVERS_REQUESTED from
# stm32_project(DRIVERS ...). See ARCHITECTURE.md §04.5.
if(USE_DRIVERS)
	if(NOT EXISTS "${CMAKE_SOURCE_DIR}/Drivers/CMakeLists.txt")
		message(STATUS "Drivers: cloning into Drivers/ ...")
		include(FetchContent)
		FetchContent_Declare(
			Drivers
			SOURCE_DIR     ${CMAKE_SOURCE_DIR}/Drivers
			GIT_REPOSITORY https://github.com/vsm-stm/STM32_Drivers_CPP.git
			GIT_TAG        refactor-for-bootloader
		)
		FetchContent_MakeAvailable(Drivers)
	else()
		message(STATUS "Drivers: Drivers/ (in-tree)")
		add_subdirectory(
			"${CMAKE_SOURCE_DIR}/Drivers"
			"${CMAKE_BINARY_DIR}/_deps/drivers-build"
		)
	endif()
	target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE stm32_drivers)
endif()

################################## LINK OPTIONS ###############################################################
target_link_libraries(${CMAKE_PROJECT_NAME} ${link_LIBS})

target_link_options(${CMAKE_PROJECT_NAME} PRIVATE
	-T${linker_script_SRC}
	${main_cpu_PARAMS}
	${cpu_PARAMS}
	${linker_OPTS}
	"-Wl,--gc-sections"
	"-Wl,-Map=${CMAKE_PROJECT_NAME}.map"
	# "-u _printf_float" # STDIO float formatting support (remove if not used)
	"--specs=nano.specs"
	"--specs=nosys.specs"
	"-Wl,--start-group"
	"-lc"
	"-lm"
	"-lstdc++"
	"-lsupc++"
	"-Wl,--end-group"
	"-Wl,-z,max-page-size=8" # Allow good software remapping across address space (with proper GCC section making)
	"-Wl,--wrap=__register_exitproc" # Wrap exit to prevent it from being called by C++ static destructors, which can cause issues in embedded environments without an OS
	"-Wl,--print-memory-usage"
)

################################## POST ###############################################################

# Execute post-build to print size, generate hex and bin
add_custom_command(TARGET ${CMAKE_PROJECT_NAME} POST_BUILD
	COMMAND ${CMAKE_SIZE} $<TARGET_FILE:${CMAKE_PROJECT_NAME}>
	COMMAND ${CMAKE_OBJCOPY} -O ihex $<TARGET_FILE:${CMAKE_PROJECT_NAME}> ${CMAKE_PROJECT_NAME}.hex
	COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${CMAKE_PROJECT_NAME}> ${CMAKE_PROJECT_NAME}.bin
	COMMAND ${CMAKE_OBJDUMP} -d -S $<TARGET_FILE:${CMAKE_PROJECT_NAME}> > ${CMAKE_PROJECT_NAME}.dis
)