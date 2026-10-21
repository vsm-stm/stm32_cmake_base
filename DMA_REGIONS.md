# DMA regions — non-cacheable DMA buffers on STM32F7

*[English](#english) · [Русский](#русский)*

---

## English

## Table of Contents

1. [Why this exists](#1-why-this-exists)
2. [Quick start](#2-quick-start)
3. [project.json reference](#3-projectjson-reference)
4. [How memory is allocated](#4-how-memory-is-allocated)
5. [Declaring buffers](#5-declaring-buffers)
6. [Using the buffers with drivers](#6-using-the-buffers-with-drivers)
7. [DMA region or ordinary cacheable buffer?](#7-dma-region-or-ordinary-cacheable-buffer)
8. [Start-up order, MPU and bootloader](#8-start-up-order-mpu-and-bootloader)
9. [Errors and how to read them](#9-errors-and-how-to-read-them)
10. [Requirements and limits](#10-requirements-and-limits)
11. [See also](#see-also)

---

## 1. Why this exists

STM32F7 (Cortex-M7) has a **data cache**. DMA reads and writes RAM directly, bypassing the cache, so the CPU and DMA can see different data:

- **TX:** the CPU wrote the buffer, but the new bytes are still in the cache → DMA sends old data from RAM.
- **RX:** DMA wrote new data to RAM, but the CPU reads stale bytes from the cache.

There are two ways to deal with it:

| Approach | How |
| --- | --- |
| Cacheable buffer + cache maintenance | The drivers clean/invalidate the cache around every transfer. The buffer must own whole 32-byte cache lines (`alignas(32)`, size padded to 32). |
| **Non-cacheable buffer (`dma_regions`)** | The buffer lives in a RAM area that the MPU marks *non-cacheable*. CPU and DMA always see the same data; no maintenance, no alignment rules. |

`dma_regions` is the second way, fully automated: you name an area in `project.json`, the build reserves memory and generates the linker sections, and `System::Init()` programs the MPU.

---

## 2. Quick start

**Step 1 — declare an area in `project.json`** (F7, drivers enabled):

```json
"drivers": ["UART"],
"dma_regions": [
  {"name": "uart_rx", "size": "0x400", "memory": "SRAM2", "mpu_region": 7}
]
```

**Step 2 — place a buffer in it** (global or `static`, without an initializer):

```cpp
__attribute__((section(".dma.uart_rx"))) static uint8_t uart_rx[256];
```

**Step 3 — use it as usual**, after `System::Init()`:

```cpp
int main()
{
    System::Init();                    // programs the MPU for all dma_regions
    // ... ClockSystem::Init<clocks>(), uart.SetUp() ...
    uart.Receive_DMA(uart_rx, sizeof(uart_rx));
}
```

During configuration CMake prints where each area went:

```text
-- firmware: DMA 'uart_rx' SRAM2 0x2004fc00 + 1024 B, MPU 7
```

---

## 3. project.json reference

```json
"dma_regions": [
  {"name": "spi",     "size": "0x8000", "memory": "SRAM1", "mpu_region": 5},
  {"name": "adc",     "size": "0x1000", "memory": "SRAM2", "mpu_region": 6},
  {"name": "uart_rx", "size": "0x400",  "memory": "SRAM2", "mpu_region": 7}
]
```

| Field | Value | Rules |
| --- | --- | --- |
| `name` | identifier | Unique; letters, digits, `_`. Becomes the section `.dma.<name>`. |
| `size` | `"0x400"` or `1024` | Power of two, **≥ 32** bytes. |
| `memory` | `"SRAM1"` or `"SRAM2"` | Internal SRAM only. |
| `mpu_region` | `1`…`7` | Unique. Region 0 is reserved (external-memory guard in `System::MPU_Init()`). |

- `[]`, `null` or a missing key — nothing is reserved (default).
- `address` is **not allowed**: addresses are always automatic.
- Only STM32F7 with drivers enabled; on F4/G0 (no D-cache) or without drivers a non-empty list is a configuration error.

---

## 4. How memory is allocated

Areas are cut from the **end** of the chosen SRAM, in list order. Each area's base address is aligned to its own size (an MPU requirement). The ordinary RAM shrinks accordingly.

Real result for STM32F746ZG with the list from section 3 (SRAM1 = `0x20010000`, 240 KB; SRAM2 = `0x2004C000`, 16 KB):

```text
-- firmware: DMA 'spi' SRAM1 0x20040000 + 32768 B, MPU 5
-- firmware: DMA 'adc' SRAM2 0x2004f000 + 4096 B, MPU 6
-- firmware: DMA 'uart_rx' SRAM2 0x2004ec00 + 1024 B, MPU 7
```

```text
           SRAM1:        3512 B       192 KB      1.79%
           SRAM2:           0 B        11 KB      0.00%
         DMA_spi:          8 KB        32 KB     25.00%
         DMA_adc:          1 KB         4 KB     25.00%
     DMA_uart_rx:         256 B         1 KB     25.00%
```

**Where did 16 KB of SRAM1 go?** SRAM1 ends at `0x2004C000`. A 32 KB area must start at a multiple of 32 KB, so the nearest base is `0x20040000`; the area covers `0x20040000…0x20047FFF`, and the 16 KB above it (`0x20048000…0x2004BFFF`) is lost to alignment. SRAM1 shrinks from 240 KB to 192 KB, not to 208 KB.

**Tips:**

- Put **larger areas first** in each bank — this reduces alignment losses.
- Prefer **SRAM2** for DMA buffers: it is a separate 16 KB bank (no contention with the stack, `.data`, `.bss` in SRAM1), and it may be used entirely.
- SRAM1 also holds `.data`, `.bss`, heap and the stack (the stack top moves down when SRAM1 shrinks), so it must keep enough room for them.
- Several buffers can share one area (e.g. `spi_tx` and `spi_rx` both in `.dma.spi`); their total must fit `size`.
- The `--print-memory-usage` lines `DMA_<name>` show how much of each area is used.

---

## 5. Declaring buffers

```cpp
// OK: global, zero-initialized
__attribute__((section(".dma.adc"))) uint16_t adc_samples[512];

// OK: static, several buffers in one area
__attribute__((section(".dma.spi"))) static uint8_t spi_tx[4096];
__attribute__((section(".dma.spi"))) static uint8_t spi_rx[4096];

// OK: a plain struct with zero-initialized members
struct Frame { uint8_t header[4]; uint8_t payload[60]; };
__attribute__((section(".dma.uart_rx"))) static Frame rx_frames[4];
```

**Rules:**

| Allowed | Not allowed |
| --- | --- |
| global / `static` variables | local (stack) variables, heap allocations — the attribute has no effect on them |
| zero initialization (no initializer, `{}`) | non-zero initializer — **silently becomes zero** (see below) |
| arrays, POD structs | objects with constructors that do work at run time |
| — | `const` data |

> ⚠ **Non-zero initializers are silently lost.** The sections are `NOLOAD`: nothing is copied from Flash, and startup zeroes the area before constructors. `uint16_t x[4] = {1, 2, 3, 4};` placed in `.dma.*` compiles and links **without any warning**, but the array is all zeros at run time. Fill such buffers in code after start-up.

- A misspelt section name (`.dma.uartrx` instead of `.dma.uart_rx`) is a **link error**: `DMA buffer needs a configured dma_regions entry`.
- No `alignas(32)` and no size padding are needed — the area is not cached.

---

## 6. Using the buffers with drivers

Nothing changes in the driver API. Pass the buffer as usual; drivers detect that the range lies inside a configured area and **skip cache maintenance automatically**.

**UART packet reception:**

```cpp
__attribute__((section(".dma.uart_rx"))) static uint8_t uart_rx[256];

if (uart.SetUp() == SysInitStatus::InitOK)
    uart.Receive_DMA(uart_rx, sizeof(uart_rx));

// main loop
if (uart.GetDataReceivedFlag()) {
    uint32_t n = uart.GetDataReceivedCount();
    // uart_rx[0..n) is valid — no invalidate needed
    uart.ClearDataReceivedFlag();
    uart.Receive_DMA(uart_rx, sizeof(uart_rx));
}
```

**ADC circular buffer** — the most useful case: with a cacheable buffer each half must start on a 32-byte boundary and occupy whole lines; here any size works and the CPU reads fresh samples directly:

```cpp
__attribute__((section(".dma.adc"))) static uint16_t adc_samples[512];

adc.IRQ_en(ADC_N::IRQ::DMA_HT, ENABLE);
adc.Start(adc_samples, 512);
// OnDmaHalf():     process adc_samples[0..255]
// OnDmaComplete(): process adc_samples[256..511]
```

**SPI full duplex:**

```cpp
__attribute__((section(".dma.spi"))) static uint8_t spi_tx[4096];
__attribute__((section(".dma.spi"))) static uint8_t spi_rx[4096];

spi.SendReceive_DMA(spi_tx, spi_rx, sizeof(spi_tx));
while (spi.Process() == SysStatus::Busy) {}
```

**TIM PWM DMA / WS2812B** — same idea: put the CCR buffer in an area and call `SendDMA()` as usual.

**Direct `DMA_Sx` use** — no `System::Cache*()` calls are needed for buffers in an area (calling them is harmless: they return immediately).

> The check is "the **whole** range lies inside **one** area". A buffer that starts in an area and runs past its end is treated as cacheable — keep buffers within `size`.

---

## 7. DMA region or ordinary cacheable buffer?

The drivers already handle cacheable buffers correctly, so `dma_regions` is optional. Choose per buffer:

| | Cacheable buffer (default) | Buffer in `dma_regions` |
| --- | --- | --- |
| Setup | `alignas(32)`, size padded to 32 bytes | one entry in `project.json` + section attribute |
| Cache maintenance | by the driver, every transfer (cost grows with buffer size) | none |
| CPU access speed | fast (cached) | slower — every access goes to SRAM |
| Circular buffers (ADC, continuous RX) | each half must own whole cache lines | any layout |
| Memory cost | only the buffer | area size + alignment losses |
| MPU regions used | none | one per area (7 available) |

**Use a DMA region when:**

- DMA runs continuously (circular ADC, audio, streaming) and the CPU reads data while DMA keeps writing;
- buffers are small or oddly sized and 32-byte padding is wasteful or awkward;
- a structure is shared between CPU and DMA (descriptors, ring buffers);
- you want to rule out cache-coherency bugs entirely.

**Keep a cacheable buffer when:** the CPU does heavy processing on the data (e.g. filtering), or memory is tight. For heavy processing you can also copy from the area into ordinary RAM first.

---

## 8. Start-up order, MPU and bootloader

```cpp
int main()
{
    System::Init();   // 1. MPU regions for dma_regions, then D-cache on
    // 2. clocks, 3. peripherals and DMA
}
```

- `System::Init()` reads the table generated by the linker and programs each area as Normal, **non-cacheable**, shareable, read/write, execute-never. If the D-cache was already on, it is cleaned/invalidated and disabled first (dirty data are kept), then re-enabled.
- **Do not start DMA before `System::Init()`**, and not from global constructors.
- Your own MPU regions keep working: choose numbers that do not collide with `dma_regions`. On overlap the **higher** region number wins, so a higher-numbered cacheable region over an area would break it.
- **Bootloader:** each image (application, bootloader) uses the `dma_regions` of **its own** `project.json`. A bootloader must stop its DMA before jumping to the application.
- Areas are not shared between images: the application's areas do not exist in the bootloader and vice versa.

---

## 9. Errors and how to read them

| Message | Cause | Fix |
| --- | --- | --- |
| `DMA buffer needs a configured dma_regions entry` (link) | section name does not match any `name` | fix the spelling or add the area |
| ``region `DMA_<name>' overflowed by N bytes`` (link) | buffers in the area are larger than `size` | increase `size` (next power of two) or move a buffer |
| `DMA area '<name>' does not fit SRAM1 with the required alignment and ordinary RAM` | area too large for the bank after alignment | smaller size, other bank, or larger areas first |
| `DMA area size must be a power of two, at least 32 bytes` | wrong `size` | use 32, 64, …, 0x4000, … |
| `DMA MPU numbers must be unique in 1..7; region 0 is reserved` | duplicate or out-of-range `mpu_region` | pick unique numbers 1…7 |
| `DMA area addresses are automatic; remove 'address'` | `address` given | remove it |
| `DMA areas support only internal SRAM1/SRAM2` | wrong `memory` | `"SRAM1"` or `"SRAM2"` |
| `dma_regions requires STM32F7 and enabled drivers` | F4/G0 or `"drivers": null` | enable drivers or remove the list |
| `update STM32_Drivers_CPP; this version does not apply dma_regions` | old drivers | use STM32_Drivers_CPP v3.0+ (`drivers_tag`) |
| `outdated F7 linker template; refresh linker-f7.ld.in` | old vendored template | refresh `cmsis-core/download_files/linker/linker-f7.ld.in` from STM32-base_files |

---

## 10. Requirements and limits

- STM32F7 only; drivers enabled; STM32_Drivers_CPP v3.0 or newer.
- Updated STM32-base_files linker template (`linker-f7.ld.in` with DMA hooks).
- Internal SRAM1/SRAM2 only; no DTCM, no external memory, no explicit addresses.
- At most 7 areas (MPU regions 1…7, minus the ones you use yourself).
- Only zero-initialized global/static buffers.

## See also

- [ReadMe.md](ReadMe.md) — `project.json` overview.
- `Drivers/System.md` — MPU and cache details, `System::Cache*()` functions.
- `Drivers/UART.md`, `Drivers/ADC.md`, `Drivers/SPI.md` — cache handover per driver.
- [ST AN4839](https://www.st.com/resource/en/application_note/an4839-level-1-cache-on-stm32f7-series-and-stm32h7-series-stmicroelectronics.pdf) — L1 cache and DMA coherency on STM32F7/H7.
- [ST AN4838](https://www.st.com/resource/en/application_note/DM00272912-.pdf) — MPU region attributes.

---

## Русский

## Содержание

1. [Зачем это нужно](#1-зачем-это-нужно)
2. [Быстрый старт](#2-быстрый-старт)
3. [Настройка в project.json](#3-настройка-в-projectjson)
4. [Как выделяется память](#4-как-выделяется-память)
5. [Объявление буферов](#5-объявление-буферов)
6. [Использование с драйверами](#6-использование-с-драйверами)
7. [DMA-область или обычный кешируемый буфер?](#7-dma-область-или-обычный-кешируемый-буфер)
8. [Порядок старта, MPU и загрузчик](#8-порядок-старта-mpu-и-загрузчик)
9. [Ошибки и как их читать](#9-ошибки-и-как-их-читать)
10. [Требования и ограничения](#10-требования-и-ограничения)
11. [См. также](#см-также)

---

## 1. Зачем это нужно

У STM32F7 (Cortex-M7) есть **кеш данных**. DMA читает и пишет RAM напрямую, в обход кеша, поэтому процессор и DMA могут видеть разные данные:

- **TX:** процессор записал буфер, но новые байты ещё в кеше → DMA отправляет старые данные из RAM.
- **RX:** DMA записал новые данные в RAM, а процессор читает устаревшие байты из кеша.

Есть два способа это решить:

| Подход | Как |
| --- | --- |
| Кешируемый буфер + обслуживание кеша | Драйверы делают clean/invalidate кеша вокруг каждой передачи. Буфер должен занимать целые 32-байтные кеш-линии (`alignas(32)`, размер дополнен до кратного 32). |
| **Некешируемый буфер (`dma_regions`)** | Буфер лежит в области RAM, которую MPU помечает как *некешируемую*. Процессор и DMA всегда видят одно и то же; ни обслуживания, ни требований к выравниванию. |

`dma_regions` — второй способ, полностью автоматизированный: вы называете область в `project.json`, сборка резервирует память и генерирует секции линкера, а `System::Init()` настраивает MPU.

---

## 2. Быстрый старт

**Шаг 1 — объявите область в `project.json`** (F7, драйверы включены):

```json
"drivers": ["UART"],
"dma_regions": [
  {"name": "uart_rx", "size": "0x400", "memory": "SRAM2", "mpu_region": 7}
]
```

**Шаг 2 — разместите в ней буфер** (глобальный или `static`, без инициализатора):

```cpp
__attribute__((section(".dma.uart_rx"))) static uint8_t uart_rx[256];
```

**Шаг 3 — используйте как обычно**, после `System::Init()`:

```cpp
int main()
{
    System::Init();                    // настраивает MPU для всех dma_regions
    // ... ClockSystem::Init<clocks>(), uart.SetUp() ...
    uart.Receive_DMA(uart_rx, sizeof(uart_rx));
}
```

При конфигурации CMake сообщает, где оказалась каждая область:

```text
-- firmware: DMA 'uart_rx' SRAM2 0x2004fc00 + 1024 B, MPU 7
```

---

## 3. Настройка в project.json

```json
"dma_regions": [
  {"name": "spi",     "size": "0x8000", "memory": "SRAM1", "mpu_region": 5},
  {"name": "adc",     "size": "0x1000", "memory": "SRAM2", "mpu_region": 6},
  {"name": "uart_rx", "size": "0x400",  "memory": "SRAM2", "mpu_region": 7}
]
```

| Поле | Значение | Правила |
| --- | --- | --- |
| `name` | идентификатор | Уникальный; буквы, цифры, `_`. Превращается в секцию `.dma.<name>`. |
| `size` | `"0x400"` или `1024` | Степень двойки, **не меньше 32** байт. |
| `memory` | `"SRAM1"` или `"SRAM2"` | Только внутренняя SRAM. |
| `mpu_region` | `1`…`7` | Уникальный. Регион 0 зарезервирован (защита внешней памяти в `System::MPU_Init()`). |

- `[]`, `null` или отсутствие ключа — ничего не резервируется (по умолчанию).
- `address` **указывать нельзя**: адреса всегда вычисляются автоматически.
- Только STM32F7 с включёнными драйверами; на F4/G0 (кеша данных нет) или без драйверов непустой список — ошибка конфигурации.

---

## 4. Как выделяется память

Области вырезаются с **конца** выбранной SRAM в порядке списка. Начало каждой области выравнивается по её собственному размеру (требование MPU). Обычная RAM соответственно уменьшается.

Реальный результат для STM32F746ZG со списком из раздела 3 (SRAM1 = `0x20010000`, 240 КБ; SRAM2 = `0x2004C000`, 16 КБ):

```text
-- firmware: DMA 'spi' SRAM1 0x20040000 + 32768 B, MPU 5
-- firmware: DMA 'adc' SRAM2 0x2004f000 + 4096 B, MPU 6
-- firmware: DMA 'uart_rx' SRAM2 0x2004ec00 + 1024 B, MPU 7
```

```text
           SRAM1:        3512 B       192 KB      1.79%
           SRAM2:           0 B        11 KB      0.00%
         DMA_spi:          8 KB        32 KB     25.00%
         DMA_adc:          1 KB         4 KB     25.00%
     DMA_uart_rx:         256 B         1 KB     25.00%
```

**Куда делись 16 КБ SRAM1?** SRAM1 заканчивается на `0x2004C000`. Область 32 КБ должна начинаться с адреса, кратного 32 КБ, поэтому ближайшее начало — `0x20040000`; область занимает `0x20040000…0x20047FFF`, а 16 КБ над ней (`0x20048000…0x2004BFFF`) теряются на выравнивание. SRAM1 уменьшается с 240 КБ до 192 КБ, а не до 208 КБ.

**Советы:**

- В каждом банке ставьте **большие области первыми** — это уменьшает потери на выравнивание.
- Для DMA-буферов лучше **SRAM2**: это отдельный банк на 16 КБ (нет конкуренции со стеком, `.data`, `.bss` в SRAM1), и его можно занять целиком.
- В SRAM1 также лежат `.data`, `.bss`, heap и стек (вершина стека опускается при уменьшении SRAM1), поэтому места для них должно хватить.
- Несколько буферов могут делить одну область (например, `spi_tx` и `spi_rx` в `.dma.spi`); их сумма должна помещаться в `size`.
- Строки `DMA_<name>` в выводе `--print-memory-usage` показывают заполнение каждой области.

---

## 5. Объявление буферов

```cpp
// Можно: глобальный, с нулевой инициализацией
__attribute__((section(".dma.adc"))) uint16_t adc_samples[512];

// Можно: static, несколько буферов в одной области
__attribute__((section(".dma.spi"))) static uint8_t spi_tx[4096];
__attribute__((section(".dma.spi"))) static uint8_t spi_rx[4096];

// Можно: простая структура с нулевыми полями
struct Frame { uint8_t header[4]; uint8_t payload[60]; };
__attribute__((section(".dma.uart_rx"))) static Frame rx_frames[4];
```

**Правила:**

| Можно | Нельзя |
| --- | --- |
| глобальные / `static` переменные | локальные (на стеке) переменные, выделения из heap — атрибут на них не действует |
| нулевая инициализация (без инициализатора, `{}`) | ненулевой инициализатор — **молча превращается в ноль** (см. ниже) |
| массивы, простые (POD) структуры | объекты с конструкторами, выполняющими работу во время старта |
| — | `const`-данные |

> ⚠ **Ненулевые начальные значения молча теряются.** Секции `NOLOAD`: из Flash ничего не копируется, а startup обнуляет область до конструкторов. `uint16_t x[4] = {1, 2, 3, 4};` в `.dma.*` компилируется и линкуется **без единого предупреждения**, но во время работы массив будет нулевым. Заполняйте такие буферы кодом после старта.

- Опечатка в имени секции (`.dma.uartrx` вместо `.dma.uart_rx`) — **ошибка линковки**: `DMA buffer needs a configured dma_regions entry`.
- `alignas(32)` и дополнение размера не нужны — область не кешируется.

---

## 6. Использование с драйверами

API драйверов не меняется. Передавайте буфер как обычно; драйвер видит, что диапазон лежит внутри настроенной области, и **автоматически пропускает обслуживание кеша**.

**Приём пакетов UART:**

```cpp
__attribute__((section(".dma.uart_rx"))) static uint8_t uart_rx[256];

if (uart.SetUp() == SysInitStatus::InitOK)
    uart.Receive_DMA(uart_rx, sizeof(uart_rx));

// основной цикл
if (uart.GetDataReceivedFlag()) {
    uint32_t n = uart.GetDataReceivedCount();
    // uart_rx[0..n) достоверен — invalidate не нужен
    uart.ClearDataReceivedFlag();
    uart.Receive_DMA(uart_rx, sizeof(uart_rx));
}
```

**Кольцевой буфер ADC** — самый полезный случай: с кешируемым буфером каждая половина должна начинаться на границе 32 байт и занимать целые линии; здесь подойдёт любой размер, а процессор сразу читает свежие отсчёты:

```cpp
__attribute__((section(".dma.adc"))) static uint16_t adc_samples[512];

adc.IRQ_en(ADC_N::IRQ::DMA_HT, ENABLE);
adc.Start(adc_samples, 512);
// OnDmaHalf():     обработать adc_samples[0..255]
// OnDmaComplete(): обработать adc_samples[256..511]
```

**SPI в полнодуплексном режиме:**

```cpp
__attribute__((section(".dma.spi"))) static uint8_t spi_tx[4096];
__attribute__((section(".dma.spi"))) static uint8_t spi_rx[4096];

spi.SendReceive_DMA(spi_tx, spi_rx, sizeof(spi_tx));
while (spi.Process() == SysStatus::Busy) {}
```

**PWM через DMA / WS2812B (TIM)** — то же самое: поместите буфер CCR в область и вызывайте `SendDMA()` как обычно.

**Прямая работа с `DMA_Sx`** — для буферов в области вызовы `System::Cache*()` не нужны (вызывать их безвредно: они сразу возвращаются).

> Проверка звучит так: «**весь** диапазон лежит внутри **одной** области». Буфер, начинающийся в области и выходящий за её конец, считается кешируемым — не выходите за `size`.

---

## 7. DMA-область или обычный кешируемый буфер?

Драйверы и так корректно работают с кешируемыми буферами, поэтому `dma_regions` — необязательная оптимизация. Выбирайте для каждого буфера:

| | Кешируемый буфер (по умолчанию) | Буфер в `dma_regions` |
| --- | --- | --- |
| Настройка | `alignas(32)`, размер кратен 32 байтам | запись в `project.json` + атрибут секции |
| Обслуживание кеша | драйвером, на каждой передаче (растёт с размером буфера) | нет |
| Скорость доступа процессора | быстро (через кеш) | медленнее — каждое обращение идёт в SRAM |
| Кольцевые буферы (ADC, непрерывный RX) | каждая половина должна занимать целые кеш-линии | любая раскладка |
| Расход памяти | только сам буфер | размер области + потери на выравнивание |
| Регионы MPU | не нужны | по одному на область (доступно 7) |

**Используйте DMA-область, когда:**

- DMA работает непрерывно (кольцевой ADC, аудио, потоковые данные) и процессор читает данные, пока DMA продолжает писать;
- буферы маленькие или нестандартного размера, и дополнение до 32 байт неудобно или расточительно;
- структура разделяется процессором и DMA (дескрипторы, кольцевые очереди);
- хотите полностью исключить ошибки согласованности кеша.

**Оставьте кешируемый буфер, когда:** процессор активно обрабатывает данные (например, фильтрация) или памяти мало. Для тяжёлой обработки можно также сначала скопировать данные из области в обычную RAM.

---

## 8. Порядок старта, MPU и загрузчик

```cpp
int main()
{
    System::Init();   // 1. регионы MPU для dma_regions, затем включение D-cache
    // 2. тактирование, 3. периферия и DMA
}
```

- `System::Init()` читает таблицу, сгенерированную линкером, и настраивает каждую область как Normal, **некешируемую**, shareable, чтение/запись, без исполнения. Если D-cache уже был включён, он сначала очищается/инвалидируется и выключается (изменённые данные сохраняются), затем включается снова.
- **Не запускайте DMA до `System::Init()`** и из глобальных конструкторов.
- Ваши собственные регионы MPU продолжают работать: выбирайте номера, не совпадающие с `dma_regions`. При перекрытии побеждает регион с **большим** номером, поэтому кешируемый регион с большим номером поверх области её сломает.
- **Загрузчик:** каждый образ (приложение, загрузчик) использует `dma_regions` из **своего** `project.json`. Загрузчик должен остановить свой DMA перед переходом в приложение.
- Области между образами не разделяются: областей приложения нет в загрузчике, и наоборот.

---

## 9. Ошибки и как их читать

| Сообщение | Причина | Что сделать |
| --- | --- | --- |
| `DMA buffer needs a configured dma_regions entry` (линковка) | имя секции не совпадает ни с одним `name` | исправить опечатку или добавить область |
| ``region `DMA_<name>' overflowed by N bytes`` (линковка) | буферы в области больше `size` | увеличить `size` (следующая степень двойки) или перенести буфер |
| `DMA area '<name>' does not fit SRAM1 with the required alignment and ordinary RAM` | область слишком велика для банка с учётом выравнивания | уменьшить размер, взять другой банк или поставить большие области первыми |
| `DMA area size must be a power of two, at least 32 bytes` | неверный `size` | 32, 64, …, 0x4000, … |
| `DMA MPU numbers must be unique in 1..7; region 0 is reserved` | повтор или неверный `mpu_region` | уникальные номера 1…7 |
| `DMA area addresses are automatic; remove 'address'` | задан `address` | удалить его |
| `DMA areas support only internal SRAM1/SRAM2` | неверный `memory` | `"SRAM1"` или `"SRAM2"` |
| `dma_regions requires STM32F7 and enabled drivers` | F4/G0 или `"drivers": null` | включить драйверы или убрать список |
| `update STM32_Drivers_CPP; this version does not apply dma_regions` | старые драйверы | STM32_Drivers_CPP v3.0+ (`drivers_tag`) |
| `outdated F7 linker template; refresh linker-f7.ld.in` | устаревший сохранённый шаблон | обновить `cmsis-core/download_files/linker/linker-f7.ld.in` из STM32-base_files |

---

## 10. Требования и ограничения

- Только STM32F7; драйверы включены; STM32_Drivers_CPP v3.0 или новее.
- Обновлённый шаблон линкера STM32-base_files (`linker-f7.ld.in` с DMA-хуками).
- Только внутренняя SRAM1/SRAM2; без DTCM, внешней памяти и явных адресов.
- Не больше 7 областей (регионы MPU 1…7, за вычетом используемых вами).
- Только глобальные/static-буферы с нулевой инициализацией.

## См. также

- [ReadMe.md](ReadMe.md) — обзор `project.json`.
- `Drivers/System.md` — подробности MPU и кеша, функции `System::Cache*()`.
- `Drivers/UART.md`, `Drivers/ADC.md`, `Drivers/SPI.md` — передача буфера между процессором и DMA в каждом драйвере.
- [ST AN4839](https://www.st.com/resource/en/application_note/an4839-level-1-cache-on-stm32f7-series-and-stm32h7-series-stmicroelectronics.pdf) — кеш L1 и согласование с DMA на STM32F7/H7.
- [ST AN4838](https://www.st.com/resource/en/application_note/DM00272912-.pdf) — атрибуты регионов MPU.
