cmake_minimum_required(VERSION 3.22)
################################## БАЗОВАЯ НАСТРОЙКА ###############################################################
include("${CMAKE_CURRENT_SOURCE_DIR}/base-setup.cmake")

# Тулчейн — регистрируется через CMAKE_TOOLCHAIN_FILE (официальный механизм,
# а не голый include()), поэтому он кешируется, попадает в
# try_compile()/ExternalProject_Add() и виден инструментам IDE. Защита
# `if(NOT ...)` означает, что явный -DCMAKE_TOOLCHAIN_FILE=... или пресет
# всё равно побеждает; иначе именно это заставляет проект собираться нужным
# компилятором даже вообще без пресета.
if(NOT CMAKE_TOOLCHAIN_FILE)
	set(CMAKE_TOOLCHAIN_FILE "${CMAKE_CURRENT_LIST_DIR}/cmake/gcc-arm-none-eabi.cmake"
		CACHE FILEPATH "STM32 arm-none-eabi toolchain" FORCE)
endif()

################################## НАСТРОЙКА ПРОЕКТА ###############################################################
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

############################# Параметры MCU / CPU + CMSIS ##################################
# скачиваем CMSIS
include("${CMAKE_CURRENT_LIST_DIR}/cmake/cmsis-download.cmake")

################################## ЦЕЛЬ ПЛАТФОРМЫ ###############################################################
# Одна INTERFACE-библиотека, несущая всё специфичное для MCU/платформы: include-
# каталоги CMSIS + устройства, дефайны устройства и флаги cpu/fpu. И
# исполняемый файл прошивки, и stm32_drivers просто линкуют её — ни тому, ни
# другому не нужно знать, где лежит cmsis-core/ и что такое STM32_CORE.
add_library(stm32_platform INTERFACE)
target_include_directories(stm32_platform INTERFACE
	${CMAKE_SOURCE_DIR}/cmsis-core/Include
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include
)
target_compile_definitions(stm32_platform INTERFACE
	${c_target}
	${STM32_DEVICE_UC}
	${STM32_CORE}
	${STM32_FLASH_def}
)
target_compile_options(stm32_platform INTERFACE -mthumb ${main_cpu_PARAMS} ${cpu_PARAMS})
target_link_options(stm32_platform    INTERFACE -mthumb ${main_cpu_PARAMS} ${cpu_PARAMS})

# Уровень оптимизации для Debug-сборок. -Og — по умолчанию (удобно для отладки,
# но оптимизировано); пресет "debug-o0" опускает его до -O0 для полностью
# пошаговой отладки (все переменные живы, без инлайна/перестановок). Читается
# в stm32_add_firmware().
set(STM32_DEBUG_OPT "-Og" CACHE STRING "Optimisation flag for Debug builds (-Og / -O0 / ...)")

################################## ДРАЙВЕРЫ ###############################################################
# stm32_drivers (STM32_Drivers_CPP) живёт внутри проекта в Drivers/. Первая
# конфигурация клонирует их туда; дальше они просто add_subdirectory()-ятся
# как есть каждую конфигурацию (FetchContent НЕ должен их ре-синкать —
# скачанные файлы правятся/коммитятся на месте). Читает STM32_DRIVERS_REQUESTED
# из stm32_project(DRIVERS ...). См. ARCHITECTURE.md §04.5.
set(_fw_libs "")
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
	list(APPEND _fw_libs stm32_drivers)
endif()

################################## ОБРАЗ ПРОШИВКИ ###############################################################
# Один декларативный вызов собирает прошиваемый образ: линкер-скрипт (под окно
# флеша этого образа), исполняемый файл, обязательную обвязку startup/newlib,
# общий набор флагов и post-build .hex/.bin/.dis. APP_START_SECTOR (из
# stm32_project()) смещает образ над загрузчиком; не задан = начало флеша.
set(_fw_sector "")
if(NOT APP_START_SECTOR STREQUAL "")
	set(_fw_sector START_SECTOR ${APP_START_SECTOR})
endif()

stm32_add_firmware(${CMAKE_PROJECT_NAME}
	${_fw_sector}
	SOURCES       ${sources_SRCS}
	INCLUDE_DIRS  ${include_DIRS}
	LINK_LIBS     ${_fw_libs}
)