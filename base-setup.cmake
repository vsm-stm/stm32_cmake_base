# ================================================================
#  base-setup.cmake — единственная точка конфигурации проекта
#  Всё, что нужно задать, задаётся одним вызовом stm32_project().
#  Имя проекта: берётся из cache-переменной prj_name (может задать
#  CMakePreset), иначе из имени папки.
# ================================================================
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Platform.cmake)

stm32_project(
	VERSION     3.1
	DESCRIPTION "Base for STM32 cmake"

	# ================================
	# MCU chip selection
	# ================================
	# DEVICE = полноценный код чипа
	# Пример: STM32F446RE, STM32F103C8, STM32G431KB
	DEVICE STM32F446RE

	# ================================
	# Memory layout (heap / stack)
	# ================================
	HEAP_SIZE  0x200   # _Min_Heap_Size
	STACK_SIZE 0x400   # _Min_Stack_Size

	# ================================
	# Drivers
	# ================================
	# DRIVERS — какие модули STM32_Drivers_CPP компилировать (system/rcc/gpio/
	# flash/irq_registry подключаются всегда, если драйверы вообще нужны).
	# Непустой список сам включает драйверы — отдельного USE_DRIVERS ON не
	# требуется. USE_DRIVERS нужен явно только чтобы взять одно ядро без
	# опциональных модулей (USE_DRIVERS ON + пустой DRIVERS) или принудительно
	# отключить всё (USE_DRIVERS OFF).
	DRIVERS
		UART SPI DMA TIM

	# ================================
	# Sources — только код приложения. startup/vector/linker и newlib-glue
	# (no_system_files/*) подключаются автоматически в CMakeLists.txt.
	# ================================
	SOURCES
		src/main.cpp

	# ================================
	# Include directories
	# ================================
	INCLUDE_DIRS
		inc
)

# ================================
# Extra user defines / options / libs (пока без отдельных именованных
# аргументов в stm32_project — расширим при первой реальной надобности)
# ================================
set(symbols_c_SYMB "")
set(symbols_cxx_SYMB "")
set(symbols_asm_SYMB "")
set(link_DIRS "")
set(link_LIBS "")
