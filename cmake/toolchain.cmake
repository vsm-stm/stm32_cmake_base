# ============================================================================
# toolchain.cmake - which compiler (bare-metal ARM, arm-none-eabi-gcc)
# ============================================================================
# Tool selection only. No compile/link flags here. Flags that do not depend
# on the configuration live in the stm32_platform target (CMakeLists.txt);
# optimization and debug info (-Og/-O0/-Os, -g*, NDEBUG) live in CMakePresets.json.
# ============================================================================

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(TOOLCHAIN_PREFIX arm-none-eabi-)   # must be on PATH

set(CMAKE_C_COMPILER   ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_ASM_COMPILER ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}g++)
set(CMAKE_OBJCOPY      ${TOOLCHAIN_PREFIX}objcopy)
set(CMAKE_OBJDUMP      ${TOOLCHAIN_PREFIX}objdump)
set(CMAKE_SIZE         ${TOOLCHAIN_PREFIX}size)

set(CMAKE_EXECUTABLE_SUFFIX_C   ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_CXX ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_ASM ".elf")

# try_compile() builds a static library, not an executable - otherwise CMake
# would try to link the probe without our linker script.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
