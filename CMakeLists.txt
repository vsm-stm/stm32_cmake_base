cmake_minimum_required(VERSION 3.24)

# ─── конфиг проекта: project.json -> CFG_* ───────────────────────────────────
include(${CMAKE_SOURCE_DIR}/cmake/functions.cmake)
stm32_read_config(${CMAKE_SOURCE_DIR}/project.json CFG)

# ─── тулчейн (только «какой компилятор»; флаги — в stm32_platform и пресетах) ─
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

# ─── скачивание CMSIS/startup/векторов + разбор CFG_device ──────────────────
#     даёт main_cpu_PARAMS, STM32_*, STM32_LINKER_TEMPLATE, STM32_STARTUP_SRCS,
#     STM32_FLASH_SECTORS, HEAP_SIZE/STACK_SIZE, RAM_* ...
include(${CMAKE_SOURCE_DIR}/cmake/cmsis-download.cmake)

# ─── stm32_platform: один INTERFACE-таргет со всеми флагами ──────────────────
#     линкуют и прошивка (stm32_add_firmware), и stm32_drivers — ни тому, ни
#     другому не нужно знать про cmsis-core/ или про cpu/fpu чипа.

# Здесь только флаги, не зависящие от конфигурации. Оптимизация и отладка
# (-Og/-O0/-Os, -g*, NDEBUG) задаются в CMakePresets.json через
# CMAKE_<LANG>_FLAGS_<CONFIG> — по одному пресету на вариант сборки.
if(NOT CMAKE_BUILD_TYPE)
	message(WARNING "CMAKE_BUILD_TYPE не задан — оптимизации нет. Используйте пресет: cmake --preset debug|release|...")
endif()

add_library(stm32_platform INTERFACE)

target_include_directories(stm32_platform INTERFACE
	${CMAKE_SOURCE_DIR}/cmsis-core/Include
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include
)
target_compile_definitions(stm32_platform INTERFACE
	${c_target}          # STM32F446xx — под этим именем CMSIS подключает регистры
	${STM32_DEVICE_UC}   # STM32F446RE
	${STM32_CORE}        # STM32F4
	"STM32_DEVICE_HEADER=\"${STM32_SERIES_LC}.h\""   # для #include STM32_DEVICE_HEADER в коде без драйверов
)
target_compile_options(stm32_platform INTERFACE
	-mthumb ${main_cpu_PARAMS}                     # cpu/fpu из *-map.cmake
	-fdata-sections -ffunction-sections            # для -Wl,--gc-sections
	$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions -fno-rtti -fno-threadsafe-statics>
	-Wall -Wextra -Wpedantic -Wno-unused-parameter
)
target_link_options(stm32_platform INTERFACE
	-mthumb ${main_cpu_PARAMS}
	-Wl,--gc-sections
	--specs=nano.specs --specs=nosys.specs
	-Wl,--start-group -lc -lm -lstdc++ -lsupc++ -Wl,--end-group
	-Wl,-z,max-page-size=8            # плотная упаковка секций по адресам
	-Wl,--wrap=__register_exitproc    # C++ статические деструкторы не нужны без ОС
	-Wl,--print-memory-usage
)

# ─── драйверы ──────────────────────────────────────────────────────────────
#     "drivers" в project.json: нет ключа / null / false = не собирать вообще;
#     true или [] = только ядро; ["UART", ...] = ядро + модули.
#     1-я конфигурация клонирует в Drivers/, дальше add_subdirectory как есть.
set(_fw_link "")
if(CFG_use_drivers)
	set(STM32_DRIVERS_REQUESTED "${CFG_drivers}" CACHE STRING
		"Опциональные модули драйверов" FORCE)
	if(EXISTS "${CMAKE_SOURCE_DIR}/Drivers/CMakeLists.txt")
		add_subdirectory(Drivers "${CMAKE_BINARY_DIR}/_deps/drivers-build")
	else()
		include(FetchContent)
		FetchContent_Declare(Drivers
			SOURCE_DIR     ${CMAKE_SOURCE_DIR}/Drivers
			GIT_REPOSITORY https://github.com/vsm-stm/STM32_Drivers_CPP.git
			GIT_TAG        v2.2)
		FetchContent_MakeAvailable(Drivers)
	endif()
	set(_fw_link stm32_drivers)
else()
	message(STATUS "Drivers: disabled (\"drivers\" = null/false/absent in project.json)")
endif()

# ─── загрузчик (как драйверы) ────────────────────────────────────────────────
#     "bootloader" в project.json: нет / null — без загрузчика, прошивка с начала
#     флеша; {"app_start_sector": N, "repo": ..., "tag": ...} — загрузчик в начале
#     флеша, секторы [0, N), приложение — с сектора N. 1-я конфигурация клонирует
#     репозиторий в Bootloader/, дальше используется локальная копия. Его
#     CMakeLists.txt НЕ используется: список файлов берётся из его project.json
#     (тем же stm32_read_config), сборкой управляет этот файл.
if(CFG_use_bootloader)
	if(NOT EXISTS "${CMAKE_SOURCE_DIR}/Bootloader/project.json")
		message(STATUS "Bootloader: cloning ${CFG_bootloader_repo} (${CFG_bootloader_tag}) into Bootloader/ ...")
		include(FetchContent)
		FetchContent_Declare(Bootloader
			SOURCE_DIR     ${CMAKE_SOURCE_DIR}/Bootloader
			GIT_REPOSITORY ${CFG_bootloader_repo}
			GIT_TAG        ${CFG_bootloader_tag}
			GIT_SHALLOW    TRUE
			SOURCE_SUBDIR  _no_cmake_here_)   # только клонируем, его CMakeLists не запускаем
		FetchContent_MakeAvailable(Bootloader)
	else()
		message(STATUS "Bootloader: Bootloader/ (in-tree)")
	endif()

	# тот же формат project.json, пути — относительно Bootloader/
	stm32_read_config("${CMAKE_SOURCE_DIR}/Bootloader/project.json" BL)
	set(_bl_sources ${BL_sources})
	if(CFG_use_drivers)
		list(APPEND _bl_sources ${BL_driver_sources})
	endif()
	stm32_add_firmware(bootloader
		SOURCES       ${_bl_sources}
		INCLUDE_DIRS  ${BL_include_dirs}
		LINK          ${_fw_link}
		START_SECTOR  0
		END_SECTOR    ${CFG_app_start_sector}
	)
endif()

# ─── образ прошивки ─────────────────────────────────────────────────────────
#     окно во флеше: без загрузчика — весь флеш; с загрузчиком — [N, конец);
#     проект-загрузчик (app_start_sector в его project.json) — [0, N).
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
