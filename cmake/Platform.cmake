# ============================================================================
# stm32_project() — единственная точка конфигурации base-проекта
# ============================================================================
#
# base-setup.cmake сводится к одному вызову:
#
#   stm32_project(
#       VERSION 3.1
#       DESCRIPTION "..."
#       DEVICE STM32F446RE
#       HEAP_SIZE 0x200
#       STACK_SIZE 0x400
#       USE_DRIVERS ON
#       DRIVERS UART SPI DMA TIM
#       SOURCES src/main.cpp ...
#       INCLUDE_DIRS inc
#   )
#
# NAME, если не задан явно, берётся из имени папки проекта, либо из
# кэш-переменной prj_name (её может выставить CMakePreset — тогда
# base-setup.cmake трогать не нужно).
#
# NOTE про DRIVERS: список просто пробрасывается как есть в cache-переменную
# STM32_DRIVERS_REQUESTED - единственный вход для STM32_Drivers_CPP/CMakeLists.txt
# (см. ARCHITECTURE.md §04.5). Какие имена модулей вообще существуют и что из
# запрошенного валидно - знает только сам drivers-репозиторий, по своей
# таблице модулей; здесь сознательно нет ни их списка, ни проверки опечаток.
# ============================================================================

function(stm32_project)
	cmake_parse_arguments(ARG
		""
		"NAME;VERSION;DESCRIPTION;DEVICE;HEAP_SIZE;STACK_SIZE;USE_DRIVERS"
		"DRIVERS;SOURCES;INCLUDE_DIRS"
		${ARGN}
	)

	# ---- валидация -----------------------------------------------------------
	if(ARG_UNPARSED_ARGUMENTS)
		message(FATAL_ERROR "stm32_project: unknown arguments: ${ARG_UNPARSED_ARGUMENTS}")
	endif()
	if(NOT ARG_DEVICE)
		message(FATAL_ERROR "stm32_project: DEVICE is required")
	endif()
	# Module names in DRIVERS are NOT validated here - see the note above.

	# ---- имя проекта: prj_name (preset) > NAME > имя папки -------------------
	if(DEFINED prj_name)
		set(ARG_NAME ${prj_name})
	elseif(NOT ARG_NAME)
		get_filename_component(ARG_NAME "${CMAKE_CURRENT_SOURCE_DIR}" NAME)
	endif()

	# ---- разумные умолчания ----------------------------------------------------
	if(NOT DEFINED ARG_VERSION)
		set(ARG_VERSION 1.0)
	endif()
	if(NOT DEFINED ARG_DESCRIPTION)
		set(ARG_DESCRIPTION "")
	endif()
	if(NOT ARG_HEAP_SIZE)
		set(ARG_HEAP_SIZE 0x200)
	endif()
	if(NOT ARG_STACK_SIZE)
		set(ARG_STACK_SIZE 0x400)
	endif()
	# USE_DRIVERS, если не задан явно, выводится из DRIVERS: непустой список =
	# драйверы нужны. Явный USE_DRIVERS ON нужен только для "хочу лишь ядро
	# (System/RCC/GPIO/Flash/IRQ) без опциональных модулей", явный OFF -
	# принудительно отключить.
	if(NOT DEFINED ARG_USE_DRIVERS)
		if(ARG_DRIVERS)
			set(ARG_USE_DRIVERS ON)
		else()
			set(ARG_USE_DRIVERS OFF)
		endif()
	endif()

	# Note: no manual "Drivers/src" include dir here anymore - once linked via
	# target_link_libraries(... stm32_drivers), the library's own PUBLIC
	# include dir (see STM32_Drivers_CPP/CMakeLists.txt) covers that.

	# ---- видимость наружу, для остального CMakeLists.txt / cmsis-download.cmake
	set(PROJECT_NAME  ${ARG_NAME}         PARENT_SCOPE)
	set(VER           ${ARG_VERSION}      PARENT_SCOPE)
	set(DESC          ${ARG_DESCRIPTION}  PARENT_SCOPE)
	set(DEVICE        ${ARG_DEVICE}       PARENT_SCOPE)
	set(HEAP_SIZE     ${ARG_HEAP_SIZE}    PARENT_SCOPE)
	set(STACK_SIZE    ${ARG_STACK_SIZE}   PARENT_SCOPE)
	set(USE_DRIVERS   ${ARG_USE_DRIVERS}  PARENT_SCOPE)
	set(sources_SRCS  ${ARG_SOURCES}      PARENT_SCOPE)
	set(include_DIRS  ${ARG_INCLUDE_DIRS} PARENT_SCOPE)

	# ---- модули драйверов: просто пробрасываем список ------------------------
	# Единственный вход для STM32_Drivers_CPP/CMakeLists.txt. Что в этом списке
	# валидно (и что вообще бывает) - знает только сам drivers-репозиторий,
	# по своей таблице модулей; он же и ругается на опечатку. FORCE - потому
	# что DRIVERS в stm32_project() и есть источник правды, он перекрывает
	# любое ручное значение при реконфигурации.
	set(STM32_DRIVERS_REQUESTED "${ARG_DRIVERS}" CACHE STRING
		"Driver modules requested via stm32_project(DRIVERS ...)" FORCE)
endfunction()
