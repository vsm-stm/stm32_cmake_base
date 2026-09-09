# ============================================================================
# gcc-arm-none-eabi.cmake — тулчейн-файл для bare-metal ARM (arm-none-eabi-gcc)
# ============================================================================
# Подключается как CMAKE_TOOLCHAIN_FILE (см. CMakeLists.txt). Задаёт кросс-
# компилятор, суффикс .elf для исполняемых файлов и STATIC_LIBRARY для
# try_compile() (иначе проба линковки без линкер-скрипта падала бы).
# ============================================================================

set(CMAKE_SYSTEM_NAME               Generic)
set(CMAKE_SYSTEM_PROCESSOR          arm)

# базовые настройки GCC
# arm-none-eabi- должен быть в PATH
set(TOOLCHAIN_PREFIX                arm-none-eabi-)
set(FLAGS                           "-fdata-sections -ffunction-sections")
set(CPP_FLAGS                       "${FLAGS} -fno-rtti -fno-exceptions -fno-threadsafe-statics")

set(CMAKE_C_FLAGS                   ${FLAGS})
set(CMAKE_CXX_FLAGS                 ${CPP_FLAGS})

set(CMAKE_C_COMPILER                ${TOOLCHAIN_PREFIX}gcc)
set(CMAKE_ASM_COMPILER              ${CMAKE_C_COMPILER})
set(CMAKE_CXX_COMPILER              ${TOOLCHAIN_PREFIX}g++)
set(CMAKE_OBJCOPY                   ${TOOLCHAIN_PREFIX}objcopy)
set(CMAKE_SIZE                      ${TOOLCHAIN_PREFIX}size)

set(CMAKE_EXECUTABLE_SUFFIX_ASM     ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_C       ".elf")
set(CMAKE_EXECUTABLE_SUFFIX_CXX     ".elf")

# try_compile() собирает статическую библиотеку, а не исполняемый файл —
# иначе CMake пытался бы слинковать пробу без нашего линкер-скрипта.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
