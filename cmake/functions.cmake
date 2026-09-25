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
#   stm32_sector_to_address()— номер сектора -> адрес + длина до конца флеша
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
#   CFG_start_sector                    — "" если null / отсутствует
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

	# --- start_sector: число, либо "" при null / отсутствии ---
	string(JSON _t ERROR_VARIABLE _e TYPE "${_cfg}" start_sector)
	if(_e OR _t STREQUAL "NULL")
		set(CFG_start_sector "" PARENT_SCOPE)
	else()
		string(JSON _v GET "${_cfg}" start_sector)
		set(CFG_start_sector "${_v}" PARENT_SCOPE)
	endif()
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
# stm32_sector_to_address(SECTOR  OUT_ADDR  OUT_LEN)
#
# SECTOR   номер сектора стирания (с 0), с которого должен начинаться образ.
# OUT_ADDR <- абсолютный начальный адрес этого сектора (напр. 0x08004000)
# OUT_LEN  <- байт от него до конца флеша (для LENGTH в линкер-скрипте)
#
# Читает STM32_FLASH_SECTORS (список "addr;size;addr;size;...", разрешённый
# в cmsis-download.cmake из скачанной map-таблицы). Конец флеша — адрес плюс
# размер последнего сектора, отдельного размера всего флеша не нужно.
# Выход за диапазон — ошибка.
# ---------------------------------------------------------------------------
function(stm32_sector_to_address SECTOR OUT_ADDR OUT_LEN)
	list(LENGTH STM32_FLASH_SECTORS _n)
	math(EXPR _count "${_n} / 2")
	if(SECTOR LESS 0 OR SECTOR GREATER_EQUAL _count)
		message(FATAL_ERROR
			"stm32_sector_to_address: sector ${SECTOR} out of range - "
			"this chip has ${_count} erase sectors (0..${_count}-1)")
	endif()

	# список плоский: [addr0 size0 addr1 size1 ...], поэтому индекс адреса = N*2
	math(EXPR _ai "${SECTOR} * 2")
	list(GET STM32_FLASH_SECTORS ${_ai} _addr)
	list(GET STM32_FLASH_SECTORS -2 _end_a)   # адрес последнего сектора
	list(GET STM32_FLASH_SECTORS -1 _end_s)   # размер последнего сектора
	math(EXPR _len "${_end_a} + ${_end_s} - ${_addr}")

	set(${OUT_ADDR} "${_addr}" PARENT_SCOPE)
	set(${OUT_LEN}  "${_len}"  PARENT_SCOPE)
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
#                           [START_SECTOR N])
#
# Собирает один прошиваемый образ. Всё общее — флаги cpu/fpu, libc, warnings,
# линкер-флаги — приходит из таргета stm32_platform (создаётся в CMakeLists.txt);
# оптимизация и отладка — из пресета (CMAKE_<LANG>_FLAGS_<CONFIG>). Здесь только
# то, что своё у каждого образа: окно флеша, линкер-скрипт, exe, post-build.
#
# START_SECTOR — номер сектора стирания, с которого начинать (с 0). Не задан =
#   вся флешка (обычный одиночный проект). > 0 — образ над загрузчиком:
#   LENGTH в линкере обрезается до "от этого сектора до конца флеша".
#
# Читает из области верхнего уровня: таргет stm32_platform (CMakeLists.txt) и
# то, что задаёт cmsis-download.cmake — STM32_LINKER_TEMPLATE,
# STM32_STARTUP_SRCS, STM32_FLASH_SECTORS, HEAP_SIZE/STACK_SIZE,
# RAM_ORIGIN/RAM_LENGTH и переменные областей MEMORY семейства (подставляются
# в шаблон линкер-скрипта). Поэтому вызывается из той же области, где
# отработал cmsis-download.cmake, — из CMakeLists.txt.
# ---------------------------------------------------------------------------
function(stm32_add_firmware TARGET)
	cmake_parse_arguments(FW "" "START_SECTOR" "SOURCES;INCLUDE_DIRS;LINK" ${ARGN})

	# --- окно флеша под этот образ ---
	if(NOT "${FW_START_SECTOR}" STREQUAL "")
		stm32_sector_to_address("${FW_START_SECTOR}" FLASH_ORIGIN FLASH_LENGTH)
	else()
		list(GET STM32_FLASH_SECTORS 0  FLASH_ORIGIN)
		list(GET STM32_FLASH_SECTORS -2 _end_a)
		list(GET STM32_FLASH_SECTORS -1 _end_s)
		math(EXPR FLASH_LENGTH "${_end_a} + ${_end_s} - ${FLASH_ORIGIN}")
	endif()

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
