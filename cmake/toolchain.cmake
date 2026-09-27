# ============================================================================
# toolchain.cmake — какой компилятор (bare-metal ARM, arm-none-eabi-gcc)
# ============================================================================
# Только выбор инструментов. Ни одного флага компиляции/линковки. Флаги,
# не зависящие от конфигурации, — в таргете stm32_platform (CMakeLists.txt);
# оптимизация и отладка (-Og/-O0/-Os, -g*, NDEBUG) — в CMakePresets.json.
# ============================================================================

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(TOOLCHAIN_PREFIX arm-none-eabi-)   # должен быть в PATH

set(CMAKE_C_COMPILER   ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_ASM_COMPILER ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}g++)
set(CMAKE_OBJCOPY      ${TOOLCHAIN_PREFIX}objcopy)
set(CMAKE_OBJDUMP      ${TOOLCHAIN_PREFIX}objdump)
set(CMAKE_SIZE         ${TOOLCHAIN_PREFIX}size)

set(CMAKE_EXECUTABLE_SUFFIX_C   ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_CXX ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_ASM ".elf")

# try_compile() собирает статическую библиотеку, а не исполняемый файл —
# иначе CMake пытался бы слинковать пробу без нашего линкер-скрипта.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
