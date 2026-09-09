# ============================================================================
# functions.cmake — примитивы загрузки / кеширования для cmsis-download.cmake
# ============================================================================
#
#   download_one()          — тянет один файл из STM32-base_files, пропускает
#                             если он уже лежит рядом (vendored)
#   stm32_sector_to_address()— номер сектора -> адрес + длина до конца флеша
#   stm32_clean_build_dir() — чистое восстановление после смены чипа
#   k_to_int()              — "128K" -> 128
#
# Всё это видно и из STM32_Drivers_CPP/CMakeLists.txt (функции глобальны сразу
# после определения, а этот файл include()-ится до того как add_subdirectory
# доходит до Drivers/): драйверы генерируют свои flash_config.h /
# irq_registry_config.h и переиспользуют для этого download_one() / k_to_int().
# ============================================================================

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
# вызывающей стороной: она удаляет весь каталог загрузки заранее (см. проверку
# смены устройства в cmsis-download.cmake), а не эта функция, гадающая про
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
# stm32_clean_build_dir()
#
# Стирает всё в текущем build-каталоге кроме CMakeCache.txt и CMakeFiles/.
# Вызывается при смене DEVICE посреди проекта (см. cmsis-download.cmake),
# чтобы следующая сборка не смешала объектные файлы под старый чип с
# заголовками/линкер-скриптами, сгенерированными под новый.
#
# CMakeCache.txt и CMakeFiles/ остаются не потому что их кто-то потом
# переиспользует, а потому что функция работает *во время* того самого прохода
# конфигурации, которому они принадлежат — удалить их из-под ещё идущей
# конфигурации сломало бы текущий запуск, а не просто убрало устаревшее.
# ---------------------------------------------------------------------------
function(stm32_clean_build_dir)
	message(STATUS "Cleaning build directory (except CMakeCache.txt)")

	file(GLOB BUILD_FILES
		"${CMAKE_BINARY_DIR}/*"
	)

	foreach(item IN LISTS BUILD_FILES)
		get_filename_component(name "${item}" NAME)

		if(NOT name STREQUAL "CMakeCache.txt"
		AND NOT name STREQUAL "CMakeFiles")
		file(REMOVE_RECURSE "${item}")
		endif()
	endforeach()
endfunction()
