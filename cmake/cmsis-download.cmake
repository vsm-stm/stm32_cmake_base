# ============================================================================
# cmsis-download.cmake — "файл, который всё скачивает"
# ============================================================================
#
# По DEVICE (напр. "STM32F446RE", задаётся в base-setup.cmake через
# stm32_project()) этот файл:
#
#   1. разбирает имя устройства на семейство/модель/букву размера флеша,
#   2. ловит смену чипа между реконфигурациями и, если она была, стирает
#      устаревшие скачанные файлы и build-каталог,
#   3. скачивает (или переиспользует уже лежащие) заголовки CMSIS, стартовый
#      код, таблицу векторов и SVD из STM32-base_files,
#   4. выбирает нужный шаблон линкер-скрипта для этого семейства.
#
# Два генерируемых заголовка flash_config.h / irq_registry_config.h здесь
# НЕ создаются — они нужны только драйверам, поэтому STM32_Drivers_CPP
# генерирует их сам. Подключение драйверов — отдельная задача, она в главном
# CMakeLists.txt (секция DRIVERS).
#
# Всё, что этот файл скачивает или генерирует, ложится в
# cmsis-core/download_files/ и должно коммититься после первой загрузки —
# см. ARCHITECTURE.md §04.4. download_one() (functions.cmake) делает шаг 3
# no-op после первой конфигурации для данного чипа.
# ============================================================================

include(${CMAKE_SOURCE_DIR}/cmake/functions.cmake)

# ============================================================================
# 1. Разбор имени устройства
# ============================================================================
# Партномера STM32 устроены так: STM32 <семейство:2> <тип:2-3> <корпус:1>
# <флеш:1> ...  напр. STM32F446RE = STM32 | F4 | 46 | R (корпус) | E (код
# размера флеша). Нам всегда нужны только три среза:
#   STM32_CORE      = первые 7 символов = "STM32F4"    (семейство: напр.
#                                                        выбирает какой
#                                                        -map.cmake/каталог
#                                                        векторов брать)
#   STM32_MODEL_UC  = первые 9 символов = "STM32F446"  (семейство + тип, по
#                                                        нему ищем точную
#                                                        строку чипа в map)
#   last_letter     = 10-й символ       = "E"          (буква кода флеша, идёт
#                                                        в имя линкер-скрипта:
#                                                        STM32F446xE.ld)
# Это позиционная нарезка строки, а не настоящий парсер — предполагается что
# DEVICE всегда 11-символьный партномер ровно этой грамматики (семейство+тип+
# корпус+буква флеша). Имя короче/длиннее или не по грамматике (напр. деталь
# без буквы корпуса) нарежется неправильно без ошибки — сверки со схемой
# именования STM32 тут нет, есть только проверка что нарезанное имя есть в
# map-таблице семейства ниже.
string(SUBSTRING "${DEVICE}" 0 11 DEVICE)

string(TOLOWER ${DEVICE} STM32_DEVICE_LC)
string(TOUPPER ${DEVICE} STM32_DEVICE_UC)
message(STATUS "Device_LC: " ${STM32_DEVICE_LC})
message(STATUS "Device_UC: " ${STM32_DEVICE_UC})

string(SUBSTRING "${STM32_DEVICE_UC}" 0 7 STM32_CORE)
string(SUBSTRING "${STM32_DEVICE_UC}" 0 11 STM32_FLASH_def) # todo
string(SUBSTRING "${STM32_DEVICE_UC}" 0 9 STM32_MODEL_UC)
string(SUBSTRING "${STM32_DEVICE_UC}" 10 1 last_letter)     # буква кода флеша

set(STM32_SERIES_UC "${STM32_CORE}xx")
set(linker_name "${STM32_MODEL_UC}x${last_letter}.ld")
string(TOLOWER ${STM32_MODEL_UC} STM32_MODEL_LC)
string(TOLOWER ${STM32_SERIES_UC} STM32_SERIES_LC)
set(c_target "${STM32_MODEL_UC}xx") # todo: выбирать на основе STM32_CORE

message(STATUS "STM32_CORE: 	 " ${STM32_CORE})
message(STATUS "STM32_FLASH_def:" ${STM32_FLASH_def})
message(STATUS "STM32_SERIES_UC: " ${STM32_SERIES_UC})
message(STATUS "STM32_SERIES_LC: " ${STM32_SERIES_LC})
message(STATUS "STM32_MODEL_UC: " ${STM32_MODEL_UC})
message(STATUS "STM32_MODEL_LC: " ${STM32_MODEL_LC})
message(STATUS "linker_name: " ${linker_name}) # todo
message(STATUS "last_letter: " ${last_letter}) # todo
message(STATUS "c_target: " ${c_target})

# ============================================================================
# 2. Обнаружение смены устройства
# ============================================================================
# STM32_CONFIGURED_DEVICE хранит в кеше CMake, под какой чип *текущий
# build-каталог* конфигурировался в последний раз. Если DEVICE с тех пор
# изменился, каждый ранее скачанный/сгенерированный файл (линкер-скрипт,
# заголовки, flash_config.h, ...) принадлежит старому чипу и переиспользовать
# его нельзя — поэтому перед повторной загрузкой стираем
# cmsis-core/download_files/ и build-каталог.
if(NOT DEFINED STM32_CONFIGURED_DEVICE)
  # Первая конфигурация
  message(STATUS
    "Initial STM32 configuration for device: ${DEVICE}"
  )

  set(STM32_CONFIGURED_DEVICE
      "${DEVICE}"
      CACHE STRING
      "STM32 device this build directory was configured for"
  )

else()
	# Повторная конфигурация
	if(NOT STM32_CONFIGURED_DEVICE STREQUAL DEVICE)
		message(WARNING
		"STM32 device changed:\n"
		"  old: ${STM32_CONFIGURED_DEVICE}\n"
		"  new: ${DEVICE}\n"
		"Cleaning downloaded STM32 files."
		)

		file(REMOVE_RECURSE
		${CMAKE_SOURCE_DIR}/cmsis-core/download_files
		${CMAKE_SOURCE_DIR}/cmsis-core/generated
		${CMAKE_SOURCE_DIR}/cmsis-core/drivers_gen
		)

		# чистим артефакты сборки
		stm32_clean_build_dir()

		set(STM32_CONFIGURED_DEVICE
			"${DEVICE}"
			CACHE STRING
			"STM32 device this build directory was configured for"
			FORCE
		)
	else()
		message(STATUS
		"STM32 device unchanged: ${DEVICE}"
		)
	endif()
endif()



# ============================================================================
# 3. Загрузка CMSIS / startup / векторов / SVD для этого устройства
# ============================================================================
# Каждый download_one() ниже — no-op, как только файл уже лежит рядом
# (см. functions.cmake) — реальная работа с сетью в этой секции только на
# первой конфигурации для данного DEVICE.

# ----------------------------------------------------------------------------
# получаем имя для таблицы векторов и файла заголовка
# ----------------------------------------------------------------------------
download_one(
	"STM32-map.cmake"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/cmake"
	"cmake/${STM32_CORE}-map.cmake")

include(${CMAKE_SOURCE_DIR}/cmsis-core/download_files/cmake/STM32-map.cmake)
# ============================
# поиск имени
# ============================
list(FIND ${STM32_CORE}_MAP "${STM32_DEVICE_UC}" IDX)

if(IDX LESS 0)
  message(FATAL_ERROR "No Name for ${STM32_DEVICE_UC}")
endif()

math(EXPR IDX_NAME   "${IDX} + 1")
math(EXPR IDX_FLASH  "${IDX} + 2")
math(EXPR IDX_RAM    "${IDX} + 3")
math(EXPR IDX_EXTRA  "${IDX} + 4")

list(GET ${STM32_CORE}_MAP ${IDX_NAME}  STM32_NAME)
list(GET ${STM32_CORE}_MAP ${IDX_FLASH} STM32_FLASH)
list(GET ${STM32_CORE}_MAP ${IDX_RAM}   STM32_RAM)
list(GET ${STM32_CORE}_MAP ${IDX_EXTRA} STM32_EXTRA)

message(STATUS "STM32_NAME   = ${STM32_NAME}")

# Раскладка секторов стирания под этот конкретный объём флеша — готовый
# список "addr;size;...", дописанный в тот же map-файл скриптом
# STM32-base_files/flash_sectors.py. Его читают stm32_sector_to_address()
# (functions.cmake) и stm32_add_firmware() (Platform.cmake); а также
# flash_config.h драйверов.
set(STM32_FLASH_SECTORS "${${STM32_CORE}_SECTORS_${STM32_FLASH}}")
if(NOT STM32_FLASH_SECTORS)
	message(FATAL_ERROR
		"cmsis-download: ${STM32_CORE}_SECTORS_${STM32_FLASH} not found for "
		"${STM32_DEVICE_UC} (${STM32_FLASH}). Regenerate the map tables with "
		"STM32-base_files/flash_sectors.py.")
endif()

# ----------------------------------------------------------------------------
# скачиваем SVD по серии и модели — STM32F4/STM32F4xx.svd
# ----------------------------------------------------------------------------

download_one(
	"SVD.svd"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files"
	"SVD/${STM32_SERIES_UC}/${STM32_MODEL_UC}.svd")

# ----------------------------------------------------------------------------
# скачиваем startup и файлы векторов
# ----------------------------------------------------------------------------

download_one(
	"startup_common.c"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup"
	"startup_c/startup_common.c")

download_one(
	"vector_${STM32_NAME}.c"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup"
	"startup_c/${STM32_SERIES_UC}/vector_${STM32_NAME}.c")

# Путь к скачанной таблице векторов — исполняемый файл компилирует её (это
# настоящий .isr_vector), а STM32_Drivers_CPP парсит её текстом, чтобы
# сгенерировать свои IRQ-заглушки.
set(STM32_VECTOR_FILE "${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/vector_${STM32_NAME}.c")

# Обязательная обвязка, которую линкует любой образ прошивки, той же категории
# что и линкер-скрипт — таблица векторов + общий startup, плюс newlib-заглушки
# ретаргета (sysmem.c = _sbrk/heap, syscalls.c = _write/_read/...).
# stm32_add_firmware() добавляет это в каждую собираемую цель.
set(STM32_STARTUP_SRCS
	${STM32_VECTOR_FILE}
	${CMAKE_SOURCE_DIR}/cmsis-core/download_files/startup/startup_common.c
	${CMAKE_SOURCE_DIR}/no_system_files/sysmem.c
	${CMAKE_SOURCE_DIR}/no_system_files/syscalls.c
)

# ----------------------------------------------------------------------------
# скачиваем заголовки STM32 и системные файлы
# ----------------------------------------------------------------------------

download_one(
	"${STM32_SERIES_LC}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/${STM32_SERIES_LC}.h")

download_one(
	"system_${STM32_SERIES_LC}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/system_${STM32_SERIES_LC}.h")

download_one(
	"system_${STM32_SERIES_LC}.c"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Source"
	"Device/${STM32_SERIES_UC}/Source/system_${STM32_SERIES_LC}.c")

download_one(
	"${STM32_NAME}.h"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/Device/Include"
	"Device/${STM32_SERIES_UC}/Include/${STM32_NAME}.h")

# ============================================================================
# 4. Линкер-скрипт: выбираем шаблон под семейство (рендер — в stm32_add_firmware)
# ============================================================================

message(STATUS "Using linker script : ${LD_TEMPLATE}")
message(STATUS "FLASH               : ${STM32_FLASH}")
message(STATUS "RAM                 : ${STM32_RAM}")
message(STATUS "EXTRA               : ${STM32_EXTRA}")

# FLASH_ORIGIN / FLASH_LENGTH здесь НЕ задаются — они зависят от стартового
# сектора линкуемого образа (загрузчик или приложение), поэтому
# stm32_add_firmware() разрешает их для каждой цели и там же рендерит
# линкер-скрипт.

set(RAM_ORIGIN 0x20000000)
set(RAM_LENGTH ${STM32_RAM})

if(NOT DEFINED HEAP_SIZE)
	set(HEAP_SIZE 0x200)
endif()
if(NOT DEFINED STACK_SIZE)
	set(STACK_SIZE 0x400)
endif()

# Каждому семейству ниже нужна своя раскладка MEMORY{}, потому что
# дополнительная область RAM (или её отсутствие) у всех разная: F7 делит RAM
# на ITCM/DTCM/SRAM1/SRAM2, у H7 своя (пока не реализовано — см. TODO ниже),
# всё с ненулевым STM32_EXTRA получает пристроенную область CCM, остальное —
# простой чип FLASH+RAM.
if(STM32_CORE STREQUAL "STM32F7")
	set(LD_TEMPLATE "linker-f7.ld.in")

	set(ITCM_ORIGIN 0x00000000)
	set(ITCM_LENGTH 16K)

	set(DTCM_ORIGIN 0x20000000)
	set(DTCM_LENGTH ${STM32_EXTRA})   # 64K или 128K

	set(SRAM2_LENGTH 16K)

	if(STM32_EXTRA STREQUAL "64K")
		set(SRAM2_ORIGIN 0x2004C000)

		set(SRAM1_ORIGIN 0x20010000)
	elseif(STM32_EXTRA STREQUAL "128K")
		set(SRAM2_ORIGIN 0x2007C000)

		set(SRAM1_ORIGIN 0x20020000)
	else()
		message(FATAL_ERROR "Invalid DTCM size for F7: ${STM32_EXTRA}")
	endif()

	k_to_int("${STM32_RAM}"   RAM_K)
	k_to_int("${DTCM_LENGTH}" DTCM_K)
	k_to_int("${SRAM2_LENGTH}" SRAM2_K)

	math(EXPR SRAM1_K
		"${RAM_K} - ${DTCM_K} - ${SRAM2_K}"
	)

	set(SRAM1_LENGTH "${SRAM1_K}K")

elseif(STM32_CORE STREQUAL "STM32H7")
	# TODO: в STM32-base_files/linker/ ещё нет linker-h7.ld.in (есть только
	# linker-simple/-f7/-ccm) — выбор H7-устройства упадёт ниже на
	# download_one("linker-h7.ld.in", ...) с 404, а не с внятной ошибкой
	# "H7 не поддерживается". Исправить в upstream до заявления поддержки H7.
	set(LD_TEMPLATE "linker-h7.ld.in")
elseif(STM32_EXTRA AND NOT STM32_EXTRA STREQUAL "-" AND NOT STM32_EXTRA STREQUAL "0K")
	set(LD_TEMPLATE "linker-ccm.ld.in")

	set(CCM_ORIGIN 0x10000000)
	set(CCM_LENGTH ${STM32_EXTRA})

	k_to_int("${STM32_RAM}"   RAM_K)
	k_to_int("${CCM_LENGTH}"  CCM_K)

	math(EXPR SRAM1_K
		"${RAM_K} - ${CCM_K}"
	)

	set(RAM_LENGTH "${SRAM1_K}K")
else()
	set(LD_TEMPLATE "linker-simple.ld.in")
endif()


download_one(
	"${LD_TEMPLATE}"
	"${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker"
	"linker/${LD_TEMPLATE}")

# Только шаблон — stm32_add_firmware() рендерит его для каждой цели (каждый
# образ задаёт свои FLASH_ORIGIN / FLASH_LENGTH от своего стартового сектора).
set(LD_IN  ${CMAKE_SOURCE_DIR}/cmsis-core/download_files/linker/${LD_TEMPLATE})

# flash_config.h (карта секторов) и irq_registry_config.h (заглушки диспетчера
# IRQ) здесь больше НЕ генерируются — оба нужны только STM32_Drivers_CPP
# (irq_registry_config.h вообще не компилируется без него), поэтому CMakeLists
# драйверов генерирует их сам из фактов о чипе, которые открывает этот файл
# (STM32_CORE / STM32_FLASH / STM32_SERIES_UC / STM32_NAME / STM32_VECTOR_FILE
# / STM32_FLASH_SECTORS). Драйверы подключаются из главного CMakeLists.txt
# (секция DRIVERS).
