# ============================================================================
# functions.cmake — все функции платформы, только определения, 0 side-effects
# ============================================================================
# include()-ится первым из CMakeLists.txt. Ничего не делает при подключении —
# просто объявляет функции (в CMake они глобальны сразу после определения, так
# что видны и из cmsis-download.cmake, и из STM32_Drivers_CPP/CMakeLists.txt).
#
#   stm32_read_config()      — project.json -> переменные CFG_* (до project())
#   stm32_add_firmware()     — собрать один прошиваемый образ
#   download_one()           — тянет один файл из STM32-base_files, пропускает
#                              если он уже лежит рядом
#   stm32_flash_window()     — сектора [START, END) -> адрес начала + длина в байтах
#   k_to_int()               — "128K" -> 128
#   stm32_sync_device()      — смена чипа: стереть чужие скачанные файлы + build,
#                              записать маркер .device
# ============================================================================

# ---------------------------------------------------------------------------
# _stm32_json_array(CFG KEY OUT)   — внутренняя: JSON-массив CFG[KEY] -> список
#   Отсутствие ключа / не-массив / пустой массив -> пустой список.
# ---------------------------------------------------------------------------
function(_stm32_json_array CFG KEY OUT)
	set(_list "")
	string(JSON _n ERROR_VARIABLE _e LENGTH "${CFG}" ${KEY})
	if(NOT _e AND _n GREATER 0)
		math(EXPR _last "${_n} - 1")
		foreach(_i RANGE ${_last})
			string(JSON _item GET "${CFG}" ${KEY} ${_i})
			list(APPEND _list "${_item}")
		endforeach()
	endif()
	set(${OUT} "${_list}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# stm32_read_config(PATH)
#
# Читает project.json и раскладывает его в переменные CFG_* в области
# вызывающего (CMakeLists.txt). Вызывается ДО project() — часть значений
# (name/version) нужны самому project().
#
#   CFG_name CFG_version CFG_device     — обязательные, иначе FATAL_ERROR
#   CFG_heap CFG_stack                  — по умолчанию 0x200 / 0x400
#   CFG_sources CFG_include_dirs        — списки (могут быть пустыми)
#   CFG_use_drivers                     — ON/OFF (см. ниже про "drivers")
#   CFG_drivers                         — список опциональных модулей
#   CFG_start_sector CFG_end_sector     — "" если null / отсутствует
#
# "drivers" в project.json:
#   нет ключа / null / false  -> драйверы не собираются вообще (CFG_use_drivers OFF)
#   true                      -> только ядро драйверов (system/rcc/gpio/flash/irq)
#   []                        -> то же, только ядро
#   ["UART", "SPI", ...]      -> ядро + перечисленные модули
#
# Вся проверка конфига — здесь, одним проходом. Формат — данные (JSON), не
# код: ошибиться и дописать логику в конфиг нельзя. Допускаются строки-
# комментарии, начинающиеся с // (как в JSONC).
# ---------------------------------------------------------------------------
function(stm32_read_config PATH)
	if(NOT EXISTS "${PATH}")
		message(FATAL_ERROR "stm32_read_config: нет файла ${PATH}")
	endif()
	file(READ "${PATH}" _cfg)

	# Строки-комментарии (первый непробельный символ — //) вырезаем: string(JSON)
	# понимает только строгий JSON. Хвостовые комментарии после значения не
	# поддерживаются, а // внутри строковых значений (URL) не затрагивается.
	string(REGEX REPLACE "(^|\n)[ \t]*//[^\n]*" "\\1" _cfg "${_cfg}")

	# --- обязательные строковые ключи ---
	foreach(_k name version device)
		string(JSON _v ERROR_VARIABLE _e GET "${_cfg}" ${_k})
		if(_e)
			message(FATAL_ERROR "project.json: нет обязательного ключа '${_k}'")
		endif()
		set(CFG_${_k} "${_v}" PARENT_SCOPE)
	endforeach()

	# --- heap / stack с умолчаниями ---
	string(JSON _v ERROR_VARIABLE _e GET "${_cfg}" heap)
	if(_e)
		set(_v "0x200")
	endif()
	set(CFG_heap "${_v}" PARENT_SCOPE)

	string(JSON _v ERROR_VARIABLE _e GET "${_cfg}" stack)
	if(_e)
		set(_v "0x400")
	endif()
	set(CFG_stack "${_v}" PARENT_SCOPE)

	# --- массивы -> списки ---
	foreach(_k sources include_dirs)
		_stm32_json_array("${_cfg}" ${_k} _list)
		set(CFG_${_k} "${_list}" PARENT_SCOPE)
	endforeach()

	# --- drivers: тристейт (см. шапку функции) ---
	string(JSON _dt ERROR_VARIABLE _e TYPE "${_cfg}" drivers)
	set(CFG_drivers "" PARENT_SCOPE)
	if(_e OR _dt STREQUAL "NULL")
		set(CFG_use_drivers OFF PARENT_SCOPE)
	elseif(_dt STREQUAL "BOOLEAN")
		string(JSON _dv GET "${_cfg}" drivers)
		set(CFG_use_drivers "${_dv}" PARENT_SCOPE)
	elseif(_dt STREQUAL "ARRAY")
		set(CFG_use_drivers ON PARENT_SCOPE)
		_stm32_json_array("${_cfg}" drivers _list)
		set(CFG_drivers "${_list}" PARENT_SCOPE)
	else()
		message(FATAL_ERROR "project.json: \"drivers\" должен быть массивом, true/false или null")
	endif()

	# --- start_sector / end_sector: число, либо "" при null / отсутствии ---
	foreach(_k start_sector end_sector)
		string(JSON _t ERROR_VARIABLE _e TYPE "${_cfg}" ${_k})
		if(_e OR _t STREQUAL "NULL")
			set(CFG_${_k} "" PARENT_SCOPE)
		else()
			string(JSON _v GET "${_cfg}" ${_k})
			set(CFG_${_k} "${_v}" PARENT_SCOPE)
		endif()
	endforeach()
endfunction()

# ---------------------------------------------------------------------------
# download_one(FILE_NAME BASE_DIR URL_DIR)
#
#   FILE_NAME — только имя файла назначения, без пути (напр. "stm32f446xx.h")
#   BASE_DIR  — каталог назначения, создаётся если его нет
#   URL_DIR   — путь файла внутри репозитория STM32-base_files, напр.
#               "Device/STM32F4xx/Include/stm32f446xx.h"
#
# Скачивает BASE_DIR/FILE_NAME из STM32-base_files, если его там ещё нет.
# Четвёртый аргумент OPTIONAL — файл необязательный (напр. SVD, нужен только
# отладчику): при неудаче выводится предупреждение, а не ошибка конфигурации.
#
# "Уже на месте и непустой" всегда побеждает и никогда не перекачивается — это
# сознательно, не просто оптимизация. В конечном проекте весь каталог загрузки
# коммитится в git (vendored, а не в .gitignore), поэтому "уже на месте"
# обычно значит "положено предыдущей конфигурацией", а не "устаревший мусор".
# Единственное, что должно форсировать перекачку — смена DEVICE — обрабатывается
# вызывающей стороной: она удаляет весь каталог загрузки заранее (см.
# stm32_sync_device()), а не эта функция, гадающая про
# устаревание каждого файла по отдельности.
# ---------------------------------------------------------------------------
function(download_one FILE_NAME BASE_DIR URL_DIR)
	set(_optional FALSE)
	if("OPTIONAL" IN_LIST ARGN)
		set(_optional TRUE)
	endif()

	set(DEST "${BASE_DIR}/${FILE_NAME}")
	set(URL  "https://raw.githubusercontent.com/vsm-stm/STM32-base_files/refs/heads/master/${URL_DIR}")

	message(STATUS "Downloading file: ${FILE_NAME}")

	# Не перекачиваем файл, который уже лежит рядом.
	if(EXISTS "${DEST}")
		file(SIZE "${DEST}" SZ)
		if(SZ GREATER 0)
			message(STATUS "File already downloaded: ${DEST}")
			return()
		endif()
	endif()

	file(MAKE_DIRECTORY "${BASE_DIR}")

	file(DOWNLOAD
		"${URL}"
		"${DEST}"
		STATUS RES
		TLS_VERIFY ON
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

	# Файл в 0 байт — обычно 404, который file(DOWNLOAD) не счёл жёсткой
	# ошибкой (напр. редирект на HTML-страницу ошибки) — ловим это здесь,
	# а не молча кладём пустой заголовок.
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
# "128K" -> 128 (убирает хвостовую "K", которой размечены таблицы flash/RAM
# во всех *-map.cmake, чтобы результат можно было скормить в math()).
# ---------------------------------------------------------------------------
function(k_to_int K_STR OUT)
	string(REPLACE "K" "" _K "${K_STR}")
	set(${OUT} ${_K} PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# stm32_flash_window(START END OUT_ORIGIN OUT_LENGTH)
#
# Окно флеша образа: сектора стирания [START, END) — START включительно, END
# НЕ включительно (это номер сектора, с которого начинается следующий образ).
#
#   START ""  -> 0                   (с начала флеша)
#   END   ""  -> число секторов чипа (до конца флеша)
#
# OUT_ORIGIN <- абсолютный адрес начала сектора START (напр. 0x08010000)
# OUT_LENGTH <- байт от него до начала сектора END (или до конца флеша)
#
# Читает STM32_FLASH_SECTORS (список "addr;size;addr;size;...", разрешённый в
# cmsis-download.cmake из скачанной map-таблицы). Конец флеша — адрес плюс размер
# последнего сектора. Нецелые значения, выход за диапазон и END <= START —
# ошибка на этапе конфигурации.
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
				"stm32_flash_window: ${_name} должен быть целым числом >= 0, "
				"получено '${${_name}}'")
		endif()
	endforeach()
	math(EXPR _last "${_count} - 1")
	if(START GREATER_EQUAL _count)
		message(FATAL_ERROR
			"stm32_flash_window: start_sector ${START} вне диапазона - у чипа "
			"${_count} секторов стирания (номера 0..${_last})")
	endif()
	if(END GREATER _count OR NOT END GREATER START)
		message(FATAL_ERROR
			"stm32_flash_window: end_sector ${END} недопустим для start_sector "
			"${START} - нужно ${START} < end_sector <= ${_count} (end_sector не "
			"включается в образ; ${_count} = до конца флеша)")
	endif()

	# список плоский: [addr0 size0 addr1 size1 ...], поэтому индекс адреса = N*2
	math(EXPR _si "${START} * 2")
	list(GET STM32_FLASH_SECTORS ${_si} _origin)

	if(END EQUAL _count)
		list(GET STM32_FLASH_SECTORS -2 _last_a)   # адрес последнего сектора
		list(GET STM32_FLASH_SECTORS -1 _last_s)   # размер последнего сектора
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
# Следит, чтобы скачанные файлы соответствовали чипу из project.json. Всё, что
# связано со сменой чипа, — здесь одним местом:
#   1. читает маркер cmsis-core/download_files/.device (под какой чип скачано);
#   2. если чип сменился (или файлы лежат без маркера — считаем чужими) —
#      стирает cmsis-core/download_files/, cmsis-core/drivers_gen/ и
#      содержимое build-каталога, кроме CMakeCache.txt и CMakeFiles/;
#   3. записывает маркер с текущим чипом.
#
# Маркер лежит рядом с файлами, а не в кеше CMake: скачанное живёт в дереве
# проекта и переживает удаление build/.
#
# CMakeCache.txt и CMakeFiles/ остаются не потому что их кто-то переиспользует,
# а потому что функция работает *во время* конфигурации, которой они
# принадлежат — удалить их из-под идущего прохода сломало бы текущий запуск.
# ---------------------------------------------------------------------------
function(stm32_sync_device DEVICE)
	set(_dl     "${CMAKE_SOURCE_DIR}/cmsis-core/download_files")
	set(_marker "${_dl}/.device")

	set(_old "")
	if(EXISTS "${_marker}")
		file(READ "${_marker}" _old)
		string(STRIP "${_old}" _old)
	endif()

	if(_old STREQUAL "" AND NOT EXISTS "${_dl}")
		message(STATUS "Initial STM32 configuration for device: ${DEVICE}")
	elseif(NOT _old STREQUAL DEVICE)
		message(WARNING
			"STM32 device changed:
"
			"  old: ${_old}  (пусто = маркера не было)
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
endfunction()

# ---------------------------------------------------------------------------
# stm32_add_firmware(TARGET  SOURCES ...  [INCLUDE_DIRS ...]  [LINK ...]
#                           [START_SECTOR N] [END_SECTOR M])
#
# Собирает один прошиваемый образ. Всё общее — флаги cpu/fpu, libc, warnings,
# линкер-флаги — приходит из таргета stm32_platform (создаётся в CMakeLists.txt);
# оптимизация и отладка — из пресета (CMAKE_<LANG>_FLAGS_<CONFIG>). Здесь только
# то, что своё у каждого образа: окно флеша, линкер-скрипт, exe, post-build.
#
# START_SECTOR — номер сектора стирания, с которого начинать (с 0). Не задан = 0.
# END_SECTOR   — номер сектора, с которого начинается СЛЕДУЮЩИЙ образ (сам не
#   входит в этот). Не задан = до конца флеша. Линкер получает FLASH LENGTH строго
#   по этому окну, поэтому образ, не влезший в свои сектора, — ошибка линковки
#   (region FLASH overflowed), а не тихое наложение на соседний образ.
#   Пример: загрузчик START 0 END 4, приложение START 4 (без END).
#
# Читает из области верхнего уровня: таргет stm32_platform (CMakeLists.txt) и
# то, что задаёт cmsis-download.cmake — STM32_LINKER_TEMPLATE,
# STM32_STARTUP_SRCS, STM32_FLASH_SECTORS, HEAP_SIZE/STACK_SIZE,
# RAM_ORIGIN/RAM_LENGTH и переменные областей MEMORY семейства (подставляются
# в шаблон линкер-скрипта). Поэтому вызывается из той же области, где
# отработал cmsis-download.cmake, — из CMakeLists.txt.
# ---------------------------------------------------------------------------
function(stm32_add_firmware TARGET)
	cmake_parse_arguments(FW "" "START_SECTOR;END_SECTOR" "SOURCES;INCLUDE_DIRS;LINK" ${ARGN})

	# --- окно флеша под этот образ ---
	stm32_flash_window("${FW_START_SECTOR}" "${FW_END_SECTOR}" FLASH_ORIGIN FLASH_LENGTH)

	# --- линкер-скрипт под эту цель ---
	set(_ld "${CMAKE_CURRENT_BINARY_DIR}/${TARGET}.ld")
	configure_file("${STM32_LINKER_TEMPLATE}" "${_ld}" @ONLY)

	# --- исполняемый файл ---
	add_executable(${TARGET})
	target_sources(${TARGET} PRIVATE ${FW_SOURCES} ${STM32_STARTUP_SRCS})
	target_include_directories(${TARGET} PRIVATE ${FW_INCLUDE_DIRS})
	target_link_libraries(${TARGET} PRIVATE stm32_platform ${FW_LINK})
	target_link_options(${TARGET} PRIVATE -T${_ld} -Wl,-Map=${TARGET}.map)

	# --- post-build: размер + .hex / .bin / .dis ---
	add_custom_command(TARGET ${TARGET} POST_BUILD
		COMMAND ${CMAKE_SIZE}    $<TARGET_FILE:${TARGET}>
		COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:${TARGET}> ${TARGET}.hex
		COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${TARGET}> ${TARGET}.bin
		COMMAND ${CMAKE_OBJDUMP} -d -S     $<TARGET_FILE:${TARGET}> > ${TARGET}.dis
	)

	message(STATUS "firmware '${TARGET}': FLASH ${FLASH_ORIGIN} + ${FLASH_LENGTH} B")
endfunction()
