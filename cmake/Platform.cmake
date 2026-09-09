# ============================================================================
# Platform.cmake — функции платформы: stm32_project() и stm32_add_firmware()
# ============================================================================
#
# stm32_project()     — единственная точка конфигурации base-проекта; разбирает
#                       декларативный вызов из base-setup.cmake и пробрасывает
#                       результат наружу (PROJECT_NAME, DEVICE, sources_SRCS...).
# stm32_add_firmware()— собирает один прошиваемый образ: линкер-скрипт под окно
#                       флеша этого образа, исполняемый файл, обвязка, флаги,
#                       post-build .hex/.bin/.dis (см. её блок ниже).
#
# ----------------------------------------------------------------------------
# stm32_project() — пример вызова:
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
#       APP_START_SECTOR 4        # если образ лежит над загрузчиком
#   )
#
# NAME, если не задан явно, берётся из имени папки проекта, либо из
# кэш-переменной prj_name (её может выставить CMakePreset — тогда
# base-setup.cmake трогать не нужно).
#
# Про DRIVERS: список просто пробрасывается как есть в cache-переменную
# STM32_DRIVERS_REQUESTED — единственный вход для STM32_Drivers_CPP/CMakeLists.txt
# (см. ARCHITECTURE.md §04.5). Какие имена модулей вообще существуют и что из
# запрошенного валидно — знает только сам drivers-репозиторий, по своей
# таблице модулей; здесь сознательно нет ни их списка, ни проверки опечаток.
# ============================================================================

function(stm32_project)
	cmake_parse_arguments(ARG
		""
		"NAME;VERSION;DESCRIPTION;DEVICE;HEAP_SIZE;STACK_SIZE;USE_DRIVERS;APP_START_SECTOR"
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
	# Имена модулей в DRIVERS здесь НЕ проверяются — см. заметку выше.

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
	# (System/RCC/GPIO/Flash/IRQ) без опциональных модулей", явный OFF —
	# принудительно отключить.
	if(NOT DEFINED ARG_USE_DRIVERS)
		if(ARG_DRIVERS)
			set(ARG_USE_DRIVERS ON)
		else()
			set(ARG_USE_DRIVERS OFF)
		endif()
	endif()

	# Примечание: ручного include-каталога "Drivers/src" здесь больше нет —
	# после линковки через target_link_libraries(... stm32_drivers) это
	# покрывает собственный PUBLIC include-каталог библиотеки (см.
	# STM32_Drivers_CPP/CMakeLists.txt).

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

	# APP_START_SECTOR — номер сектора стирания, с которого должен начинаться
	# образ. Не задан = начало флеша (сектор 0). Задаётся, когда этот проект —
	# приложение, которое должно лежать над загрузчиком. Читается
	# stm32_add_firmware() в CMakeLists.txt.
	set(APP_START_SECTOR "${ARG_APP_START_SECTOR}" PARENT_SCOPE)

	# ---- модули драйверов: просто пробрасываем список ------------------------
	# Единственный вход для STM32_Drivers_CPP/CMakeLists.txt. Что в этом списке
	# валидно (и что вообще бывает) — знает только сам drivers-репозиторий,
	# по своей таблице модулей; он же и ругается на опечатку. FORCE — потому
	# что DRIVERS в stm32_project() и есть источник правды, он перекрывает
	# любое ручное значение при реконфигурации.
	set(STM32_DRIVERS_REQUESTED "${ARG_DRIVERS}" CACHE STRING
		"Driver modules requested via stm32_project(DRIVERS ...)" FORCE)
endfunction()


# ============================================================================
# stm32_add_firmware(TARGET [START_SECTOR N] [SOURCES ...] [INCLUDE_DIRS ...]
#                           [LINK_LIBS ...])
# ============================================================================
#
# Собирает один прошиваемый образ:
#   - рендерит шаблон линкер-скрипта семейства под этот конкретный образ
#     (свои FLASH_ORIGIN / FLASH_LENGTH, выведенные из START_SECTOR),
#   - создаёт исполняемый файл, добавляет поверх SOURCES обязательную обвязку
#     startup/векторов/newlib (STM32_STARTUP_SRCS),
#   - линкует stm32_platform (+ любые LINK_LIBS), применяет общий набор флагов
#     предупреждений / оптимизации / линкера,
#   - на этапе post-build генерирует .hex / .bin / .dis и печатает размер +
#     использование памяти.
#
# START_SECTOR — номер сектора стирания, с которого начинать (с 0). Не задан =
#   сектор 0 (начало флеша), т.е. обычный проект из одного образа. Значение > 0
#   — так приложение размещается над загрузчиком; LENGTH в линкере обрезается
#   до "от этого сектора до конца флеша".
#
# Опирается на переменные, заданные раньше в области верхнего уровня файлом
# cmsis-download.cmake (STM32_FLASH_SECTORS, STM32_STARTUP_SRCS, LD_IN,
# RAM_ORIGIN/RAM_LENGTH, HEAP_SIZE/STACK_SIZE, переменные областей MEMORY
# семейства) и base-setup.cmake (symbols_*_SYMB, compiler_OPTS, linker_OPTS) —
# поэтому вызывать её нужно из той же области каталога (главный CMakeLists.txt),
# после include(cmsis-download).
# ============================================================================
function(stm32_add_firmware TARGET)
	cmake_parse_arguments(FW "" "START_SECTOR" "SOURCES;INCLUDE_DIRS;LINK_LIBS" ${ARGN})

	# ---- окно флеша под этот образ ----------------------------------------
	if(DEFINED FW_START_SECTOR AND NOT FW_START_SECTOR STREQUAL "")
		stm32_sector_to_address("${FW_START_SECTOR}" FLASH_ORIGIN FLASH_LENGTH)
	else()
		# весь чип: от сектора 0 до конца последнего сектора
		list(GET STM32_FLASH_SECTORS 0  FLASH_ORIGIN)
		list(GET STM32_FLASH_SECTORS -2 _end_a)
		list(GET STM32_FLASH_SECTORS -1 _end_s)
		math(EXPR FLASH_LENGTH "${_end_a} + ${_end_s} - ${FLASH_ORIGIN}")
	endif()

	# ---- линкер-скрипт, рендерится под каждую цель -----------------------
	set(_ld "${CMAKE_CURRENT_BINARY_DIR}/${TARGET}.ld")
	configure_file("${LD_IN}" "${_ld}" @ONLY)

	# ---- исполняемый файл ----------------------------------------------
	add_executable(${TARGET})
	target_sources(${TARGET} PRIVATE ${FW_SOURCES} ${STM32_STARTUP_SRCS})
	target_include_directories(${TARGET} PRIVATE ${FW_INCLUDE_DIRS})
	target_link_libraries(${TARGET} PRIVATE stm32_platform ${FW_LINK_LIBS} ${link_LIBS})

	target_compile_definitions(${TARGET} PRIVATE
		${symbols_SYMB}
		$<$<COMPILE_LANGUAGE:C>:${symbols_c_SYMB}>
		$<$<COMPILE_LANGUAGE:CXX>:${symbols_cxx_SYMB}>
		$<$<COMPILE_LANGUAGE:ASM>:${symbols_asm_SYMB}>
	)

	target_compile_options(${TARGET} PRIVATE
		# флаги cpu/fpu приходят из stm32_platform (слинкован выше)
		${compiler_OPTS}
		-Wall -Wextra -Wpedantic -Wno-unused-parameter
		$<$<CONFIG:Debug>:${STM32_DEBUG_OPT} -g3 -ggdb>
		$<$<CONFIG:Release>:-Os -g0>
	)

	target_link_options(${TARGET} PRIVATE
		-T${_ld}
		${linker_OPTS}
		"-Wl,--gc-sections"
		"-Wl,-Map=${TARGET}.map"
		"--specs=nano.specs"
		"--specs=nosys.specs"
		"-Wl,--start-group" "-lc" "-lm" "-lstdc++" "-lsupc++" "-Wl,--end-group"
		"-Wl,-z,max-page-size=8"
		"-Wl,--wrap=__register_exitproc"
		"-Wl,--print-memory-usage"
	)

	# ---- post-build: размер + .hex/.bin/.dis ---------------------------
	add_custom_command(TARGET ${TARGET} POST_BUILD
		COMMAND ${CMAKE_SIZE}    $<TARGET_FILE:${TARGET}>
		COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:${TARGET}> ${TARGET}.hex
		COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${TARGET}> ${TARGET}.bin
		COMMAND ${CMAKE_OBJDUMP} -d -S     $<TARGET_FILE:${TARGET}> > ${TARGET}.dis
	)

	if(DEFINED FW_START_SECTOR AND NOT FW_START_SECTOR STREQUAL "")
		set(_where " (start sector ${FW_START_SECTOR})")
	else()
		set(_where "")
	endif()
	message(STATUS
		"firmware '${TARGET}': FLASH ORIGIN=${FLASH_ORIGIN} LENGTH=${FLASH_LENGTH} B${_where}")
endfunction()
