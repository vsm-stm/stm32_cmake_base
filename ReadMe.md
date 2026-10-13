# STM32 CMake Base

*[English](#english) · [Русский](#русский)*

---

## English

This repository is a starter template for bare-metal `STM32` development in
`C/C++` using `CMake`, `arm-none-eabi-gcc`, `CMSIS`, and the author's own set
of drivers. The project is set up to work from `VS Code`, but is not tied to
an IDE and builds from the command line just as well.

The repository's core idea:

- spin up a new STM32 project quickly, without CubeMX;
- generate the linker script for the chosen chip automatically;
- pull CMSIS/device/startup files straight from an external repository.

This is specifically a starting base for an application, not the application itself.

## What's inside

At the top level:

- `project.json` — the **single configuration file**: name, version, chip, heap/stack,
  driver list, sources, include paths, bootloader (`bootloader`). Data only, no code.
- `CMakeLists.txt` — the glue: config → toolchain → `project()` → downloads →
  the `stm32_platform` target (flags that do not depend on the configuration) →
  drivers → `stm32_add_firmware()`. Rarely edited.
- `CMakePresets.json` — the `debug`, `debug-o0`, `release`, `relWithDebInfo`,
  `minSizeRel` presets. Also the **single place for optimization/debug flags**
  (`-Og/-O0/-Os`, `-g*`, `NDEBUG`) — via `CMAKE_<C|CXX>_FLAGS_<CONFIG>`.
- `cmake/functions.cmake` — every platform function (reading the config,
  `stm32_add_firmware`, downloading files), definitions only.
- `cmake/cmsis-download.cmake` — procedural, runs once: downloads
  CMSIS/startup/vectors, parses the chip, picks the linker script template.
  Only fetches files and facts — no flags here.
- `cmake/toolchain.cmake` — picks the `arm-none-eabi-*` compiler.
- `src/` — the application's own code (a CMSIS example).
- `inc/` — the application's own headers (`main.hpp` — commented-out driver includes).
- `Drivers/` — the `STM32_Drivers_CPP` library; cloned on the first configure
  if `"drivers"` is enabled (in `.gitignore`).
- `Bootloader/` — the bootloader repository; cloned if `"bootloader"` is set
  in `project.json` (in `.gitignore`).
- `no_system_files/` — `syscalls.c` and `sysmem.c` for newlib/newlib-nano.
- `cmsis-core/` — the local base of CMSIS Core headers.
- `cmsis-core/download_files/` — the downloaded startup/device/linker/SVD
  files for the selected MCU.
- `.vscode/` — ready-made tasks, flashing, and debugging via ST-Link.

## What the project does during configure

During `cmake configure`, the project:

1. `stm32_read_config()` reads `project.json` into `CFG_*` variables and validates them.
2. Takes the target microcontroller's name (`CFG_device`), determines the
   family, startup file, device headers, and memory sizes.
3. Downloads any missing files from the `STM32-base_files` repository:
   - `startup_common.c`
   - `vector_<device>.c`
   - device headers
   - `system_<series>.h`
   - `SVD`
   - the linker script template
4. Creates the `stm32_platform` target in `CMakeLists.txt` — every compiler
   and linker flag in one place.
5. If `"drivers"` is not `null`/`false` — links in `Drivers/` (the first
   configure clones it).
6. If `"bootloader"` is set — clones `Bootloader/` and builds it as the first
   `bootloader` image, in sectors `[0, N)`.
7. `stm32_add_firmware()` renders the `.ld` for the image's flash window and
   builds `.elf/.hex/.bin/.dis` (for the application with a bootloader — starting at sector `N`).

The drivers generate `flash_config.h` / `irq_registry_config.h` themselves
(these are their own internal headers).

The `cmsis-core/download_files/.device` marker remembers which chip the files
were downloaded for. If `"device"` changed (or the files are sitting there
without a marker), `cmake/cmsis-download.cmake` wipes the downloaded files and
build artifacts and re-downloads — even after `rm -rf build`.

## Runtime and build contracts

### Dedicated generated directories

`build/<preset>/`, `cmsis-core/download_files/` and `cmsis-core/drivers_gen/`
contain disposable build/download/generated files only. **Do not put your
own sources, headers or documents there.** A device change or a platform
format update removes their contents; CMakeCache.txt/CMakeFiles are retained
while configure is running. Put your code in src/inc and list it in project.json.
In-source builds and builds in an ancestor of the source root are rejected.

The platform format is now 2: startup, linker templates and maps must be
updated together. Older generated/downloaded files are refreshed once on
configure. The new linker tables use byte counts and names beginning with
`__stm32_` to avoid collisions with the CMSIS startup ABI.

### Minimal startup and FPU

Startup copies initialized RAM/code and clears zero-initialized sections
through tables supplied by the linker: .data/.bss, CCM, ITCM, DTCM and SRAM2.
It sets this image's VTOR where available, keeps IRQ disabled during memory
initialization/constructors, and enables IRQ immediately before main.
Returning from main enters a terminal loop.

When `__FPU_PRESENT == 1` and `__FPU_USED == 1`, startup enables access to
CP10/CP11 through `SCB->CPACR` after RAM initialization. One shared `DSB`/`ISB`
pair follows FPU/VTOR/core mask configuration before constructors.
The FPU block is omitted for devices/builds without
hardware FPU use. Global/static constructors may therefore use float/double;
FPU access does not depend on calling `System::Init()` from main.
The drivers retain their FPU initialization for use with other startups.
The platform exports `STM32_STARTUP_ENABLES_FPU` to firmware and drivers, so
`System::Init()` skips the CPACR write and barriers already handled by startup.
If replacing startup, remove this definition unless the replacement enables FPU.
The base platform provides no separate FPU initialization API.
When `bootloader` is configured in project.json, the platform also exports
`STM32_USE_BOOTLOADER` to both images and the shared driver library. It enables
the separate preparation function in `System::Init()` for F4/F7/G0: HSI,
dividers /1, G0 VOS Range 1 and Flash latency 0. VOS/latency timeouts remain
100 ms. Without the macro, call `System::Init()` once after hardware reset,
before clock configuration; that preparation code is excluded from compilation.
Pre-main constructors must not wait for IRQ-driven work: IRQ is still masked.
Vendor `system_stm32*.c`, SystemInit and the global CMSIS clock API are not
used/downloaded. `system_stm32*.h` is retained because device headers include it.
Use `System::SystemCoreClock` with drivers, or maintain your own clock state.

### Flash bank modes and dependencies

`flash_bank_mode` accepts `"single"` / `"dual"`. Missing/null selects the fixed
mode on single-only/dual-only devices; switchable devices default to single.
Unsupported explicit modes are configuration errors. F429ZI (2 MiB) therefore
uses both banks automatically. The base and driver share the same resolved
format-3 erase map: address, size, bank and hardware erase selector.

The device table's `FLASH_LAYOUT` column selects the shared geometry directly.
Supported modes are determined by the presence of single/dual erase lists;
there are no separate device-to-layout or supported-mode tables.

F4 1 MiB bank-capable variants use DB1M; F76/F77 use nDBANK; G0B1/C1 256 KiB
use DUAL_BANK. The Flash driver checks the actual mode during initialization
and returns SysInitStatus::InitError on mismatch or active bank swap. Fixed
modes ignore irrelevant option bits. Programming option bytes remains the
user's responsibility; reset the MCU after changing them. With drivers disabled,
the CMSIS application must check its own hardware configuration.

For G4 category 3, single pages are 4 KiB and dual pages 2 KiB. The 128/256 KiB
dual variants have an address gap before bank 2 at 0x08040000. Ordinary code,
constants and RAM initializers stay in the first contiguous bank of the selected
image window; `.flash_bank2` explicitly places const data or functions in the
available second bank. The linker excludes the gap and limits both regions to
the image's sector window. The logical `app_start_sector` indexes the erase map,
including bank 2; it is not the hardware erase selector.

```cpp
__attribute__((section(".flash_bank2"))) const uint32_t table[16] = {1, 2, 3};
```

Contiguous single/dual layouts use the ordinary single `FLASH` region. Only
G4 layouts with a gap add `FLASH_BANK2` and the explicit `.flash_bank2` section.
ELF/HEX retain both regions' addresses. The usual BIN generation is unchanged;
if both regions contain data, BIN includes padding across the address gap.
No separate bank-2 binary is generated.

G0B0/B1/C1 and L071/L072/L073 category-5 variants are now in the maps. Flash driver
support remains F4/F7/G0. H7 erase maps are updated (including H7A3/B3 8 KiB pages),
but its platform linker/runtime support remains a separate task.

Update the base, drivers and base_files together. Refresh the vendored
STM32-map.cmake, flash_config.h.in and linker template from this base_files
version, or set STM32_BASE_FILES_DIR to its local checkout. Old format-2 maps
and old flash_config templates are rejected. This is also necessary in an
existing copied project: updating only the source repositories
does not replace that project's copies of cmake/*.cmake.

Every read project.json is a configure dependency; every generated .ld is a
link dependency. Changing heap/stack followed by build applies the new layout
without clean rebuild. Debug presets define DEBUG for platform consumers.

For development with these adjacent repositories, use local dependencies:

```powershell
cmake --preset debug -DSTM32_BASE_FILES_DIR=../STM32-base_files -DFETCHCONTENT_SOURCE_DIR_DRIVERS=../STM32_Drivers_CPP -DFETCHCONTENT_SOURCE_DIR_BOOTLOADER=../stm32-bootloader
```

The base-files override copies from that directory and tracks file changes.
Remote files remain vendored after the first download. For reproducible
projects, commit the downloaded files and select a fixed bootloader tag/revision.
Coordinated changes here and in STM32-base_files/bootloader/drivers must be
available locally or published upstream before a clean remote configure.

`bootloader.extra_sources: []` adds no extra files. The selected bootloader's
own sources still build; it needs one user implementation of bl_stay, not
another main. The updated bootloader supports the F4/F7 PWR interfaces and VTOR;
use the updated startup to restore IRQ after the jump.

To retarget stdio, define `int __io_putchar(int)` and `int __io_getchar(void)`
(C linkage from C++), or override the weak _write/_read stubs. Missing hooks
return ENOSYS; output errors yield EIO/short writes; a negative input result is EOF.
Do not call malloc/free from IRQ; the supplied heap is not an ISR allocator.

Change details and verification are in [BASE_FIXES.md](BASE_FIXES.md).

## What this repository is a good fit for

The repository is a good fit if you need:

- a bare-metal project with no HAL;
- file-level control over startup/linker/CMSIS;
- building via `CMake` and `Ninja`;
- working in `VS Code` with `CMake Tools` and `cortex-debug`;
- a base for your own driver library.

## Example application

The current `src/main.cpp` is a minimal plain-CMSIS example (no drivers,
`"drivers": null`):

- enables `GPIOA` clocking (`RCC->AHB1ENR`);
- sets `PA5` (the Nucleo-F446RE LED) to output;
- toggles it forever with a software delay.

The example is written for F4; on another family, replace the port clock
enable. The chip header is included as `#include STM32_DEVICE_HEADER` (the
define is set by the platform).

A commented-out drivers-based variant is left in the code (`System::Init()`,
`ClockSystem::CalcPLL(...)` + `ClockSystem::Init<clocks>()`, `System::Enable_CYCCNT()`, `NUCLEO_LED`);
to enable it, set `"drivers": true` and uncomment the drivers-core includes
in `inc/main.hpp`.

## Requirements

Working with the project needs:

- `CMake` version `3.24+`
- `Ninja`
- the `arm-none-eabi-gcc` toolchain on `PATH`
- `arm-none-eabi-g++`
- `arm-none-eabi-objcopy`
- `arm-none-eabi-objdump`
- `arm-none-eabi-size`
- `git`

For flashing and debugging, also:

- the `STM32CubeProgrammer` CLI (`STM32_Programmer_CLI.exe`)
- an `ST-Link`
- for debugging from VS Code: the `cortex-debug` extension
- for working with CMake in VS Code: the `ms-vscode.cmake-tools` extension

## Quick start

### 1. Configure the project

Everything lives in one file — `project.json`. Whole-line comments starting
with `//` are allowed (as in JSONC; in VS Code the file is already associated
with the `jsonc` mode, so highlighting does not complain). Trailing comments
after a value are not supported. Here is an example without comments:

```json
{
  "name":         "firmware",
  "version":      "3.2",
  "device":       "STM32F446RE",
  "flash_bank_mode": null,
  "heap":         "0x200",
  "stack":        "0x400",
  "drivers":      null,
  "dma_regions":  [],
  "sources":      ["src/main.cpp"],
  "include_dirs": ["inc"],
  "bootloader":   null
}
```

- `device` — the full chip part number (`STM32F446RE`, `STM32F429ZG`,
  `STM32F407VG`); must match the grammar `cmake/cmsis-download.cmake` understands.
- `drivers` — whether to pull in the `STM32_Drivers_CPP` library:
  - `null` / `false` / key absent — drivers are not built at all (plain CMSIS + your own code);
  - `true` or `[]` — core only (system / rcc / gpio / flash / irq_registry);
  - `["UART", "SPI", "DSP", ...]` — core + the listed optional modules
    (`UART`, `SPI`, `DMA`, `TIM`, `RTC`, `ADC`, `DAC`, `I2C`, `MODBUS`,
    `CONTAINERS`, `PID` — the author's own PID controller, `DSP` — a subset
    of Arm's CMSIS-DSP).

  Drivers support STM32 **F4 / F7 / G0**. For other families (including G4),
  set `null` and write your own register-level code, or port the drivers.
- `sources` / `include_dirs` — your code and include paths.
- `bootloader` — `null` / key absent: no bootloader, firmware starts at the
  beginning of flash (no sectors). `{"app_start_sector": N, "repo": "...",
  "tag": "...", "extra_sources": [...]}` (`repo`/`tag`/`extra_sources` are
  optional; `repo`/`tag` default to `vsm-stm/stm32-bootloader`, `main`):
  bootloader at the start of flash (sectors `[0, N)`), firmware starts at
  sector `N`. The platform clones the repository into `Bootloader/` (like
  `Drivers/`) and builds it as a **second image** in this same project: it
  takes the `sources` / `include_dirs` lists from its own `project.json`; its
  `CMakeLists.txt` is not used. `stm32-bootloader` is a small library (image
  check, jump, update flag) with its own `main()`. `extra_sources` implements
  `bl_stay(bl_stay_reason_t)` and its transport/hardware code: files of THIS
  project (paths relative to its own `project.json`) that get added to the
  bootloader image build. Both projects' `include_dirs` are now shared both
  ways: the bootloader sees this project's `include_dirs`, and this project
  sees the bootloader's `include_dirs` (usually `Bootloader/src`, which holds
  headers shared by both sides, such as the "update requested" flag; nothing
  is copy-pasted). Every image gets `STM32_IMAGE_FLASH_ORIGIN/END`. An image
  that does not fit its sectors is a link error (`region FLASH overflowed`).
  Firmware starting at sector `N > 0` will not run on its own: on reset the
  core takes the vector table from `0x08000000` — the bootloader has to be the
  one that runs it.

The standalone bootloader (`stm32-bootloader`) downloads this platform's own
files (`cmake/`, `no_system_files/`, `cmsis-core/Include`) into its own tree
and runs the same build script; its `project.json`'s top-level `app_start_sector`
key sets `[0, N)`. The `STM32_DEVICE_HEADER` define (`"stm32f4xx.h"`) lets
code without drivers write `#include STM32_DEVICE_HEADER`.

#### Non-cacheable DMA buffers (STM32F7)

`dma_regions` is optional. Missing/null/`[]` reserves no memory. A nonempty list
requires F7 and enabled drivers (`true`, `[]` or a module list); on F4/G0 or
without drivers it is a configuration error. Only internal SRAM1/SRAM2 is supported:

```json
"dma_regions": [
  {"name": "adc", "size": "0x4000", "memory": "SRAM2", "mpu_region": 7}
]
```

Names are unique identifiers. Sizes are powers of two, at least 32 bytes.
MPU numbers are unique in 1..7; region 0 is reserved. Addresses are automatic,
allocated from the selected bank's end in list order and aligned to each area's
size. Alignment gaps are reserved too. Larger areas first can reduce wasted
alignment space. Ordinary RAM length shrinks accordingly, including the stack
top for SRAM1 and available `.sram2_bss` space for SRAM2. SRAM2 may be used entirely;
SRAM1 must still accommodate ordinary data/heap/stack. Exhaustion is a configuration
or link error. Explicit `address` and external memory are unsupported.

```cpp
__attribute__((section(".dma.adc"))) static uint16_t adc_buffer[1024];
```

Only global/static zero-initialized buffers are supported. Their sections are
NOLOAD and are zeroed through the existing startup table before constructors.
Do not use nonzero initializers or objects with dynamic initialization: initial
contents are not copied from Flash. Unconfigured `.dma.*` sections are link errors.

Call `System::Init()` before setting up peripherals or starting DMA. It sets
the named MPU regions to Normal non-cacheable, shareable, read/write, execute-never,
then enables D-cache. If the cache was already enabled, it is disabled with
clean/invalidate first to preserve dirty data. Other MPU regions remain;
avoid collisions with your own region numbers or higher-priority overlapping maps.
Constructors must not start DMA; a bootloader must stop its DMA before handover.
Normal stack/heap/data buffers remain outside these areas.

The feature requires updated **drivers and base_files**. Configuration rejects
old driver versions and F7 linker templates. For local base_files development,
set `STM32_BASE_FILES_DIR` to the updated checkout; otherwise refresh the project's
vendored `cmsis-core/download_files/linker/linker-f7.ld.in`. Application and bootloader
use their own `project.json` areas independently. See the drivers' `System.md`
for MPU/cache details. DMA cache maintenance in the remaining drivers is a later step.

Flags: ones that do not depend on the configuration live in the
`stm32_platform` target in `CMakeLists.txt`; optimization and debug info live
in `CMakePresets.json`. There are no flags in `project.json`.

### 2. Configure and build

From the repository root:

```powershell
cmake --preset debug
cmake --build --preset debug
```

For a release build:

```powershell
cmake --preset release
cmake --build --preset release
```

Artifacts land in:

```text
build/<preset>/
```

After the build, these are created automatically:

- `.elf`
- `.hex`
- `.bin`
- `.map`
- `.dis`

## Working from VS Code

The repository already has:

- `CMakePresets.json`
- `.vscode/tasks.json`
- `.vscode/launch.json`
- `.vscode/settings.json`

Already set up:

- build via the active `CMake` preset (`CMake: Build`);
- flashing the application via `STM32_Programmer_CLI.exe` over `SWD`
  (`STM32Prog: Flash app (SWD)`) — flashes the active CMake launch target; with
  a bootloader, pick the application (not `bootloader`) in the CMake status
  bar first;
- flashing the bootloader (`STM32Prog: Flash bootloader (SWD)`) and both
  images in sequence (`Build + Flash all`) — if `bootloader` is set in `project.json`;
- full chip erase;
- debugging via `cortex-debug`: `ST-Link Launch` / `ST-Link Attach` (ST-Link's
  own GDB server), `ST-Link-OCD` / `ST-Link-OCD-SWO` (OpenOCD, family picked
  at launch; SWO is trace output), `VS_Launch` (ST's own VS Code extension);
- using the locally downloaded `SVD` file.

Status bar buttons (the "Task Buttons" extension, `VsCodeTaskButtons.tasks`
in `settings.json`) mirror the tasks, so the command line is not needed:
`Configure`, `Build`, `Rebuild`, `Build+Flash`, `Flash all` (bootloader +
application), `Flash BL`, `Flash App`, `Reset`, `Erase`, `Probes`.

For **debugging** (not flashing) you need a CMake target
(`cmake.launchTargetPath`) — with a bootloader there are two targets
(`bootloader` and `firmware`), pick the one you need in the CMake status bar; see below.

A typical VS Code workflow:

1. Open the project folder.
2. Pick a configure preset, e.g. `debug`.
3. Run `CMake: Configure`.
4. Run `CMake: Build`.
5. Run the `STM32Prog: Flash app (SWD)` task, or `Build + Flash` (with a
   bootloader — `Build + Flash all`).
6. For debugging, pick a configuration from `launch.json` (see above).

Debugging an application that has a bootloader: flash both images, select the
`firmware` target, and use `ST-Link Attach`. Running `ST-Link Launch`
reflashes and resets the core; the application only starts via the
bootloader, which hands control to it.

## Flashing from the command line

If `STM32_Programmer_CLI.exe` is on `PATH`, you can flash like this:

```powershell
STM32_Programmer_CLI.exe --connect port=swd --download build/debug/<project>.elf --start
```

With a bootloader — flash the bootloader first, then the application
(addresses are baked into the ELF):

```powershell
STM32_Programmer_CLI.exe --connect port=swd --download build/debug/bootloader.elf
STM32_Programmer_CLI.exe --connect port=swd --download build/debug/<project>.elf --start
```

List available interfaces:

```powershell
STM32_Programmer_CLI.exe --list
```

Full erase:

```powershell
STM32_Programmer_CLI.exe --connect port=swd --erase all
```

## Adding your own code

Usually all you need is:

1. Add `.cpp/.c` files to `src/`.
2. Add headers to `inc/`.
3. List the new sources in `"sources"` in `project.json`.
4. Add include paths to `"include_dirs"` if needed.
5. Add any needed driver modules to the `"drivers"` array.

## Switching the project to a different STM32

1. Change `"device"` in `project.json`.
2. Reconfigure the project: `cmake --preset debug`.
3. If needed, delete the old `build/` directory if it still holds artifacts
   from a different chip.
4. For OpenOCD debugging, pick the new chip's family when launching the
   profile (see below). Nothing else in `.vscode` needs changing.

### What in `.vscode` does not depend on the chip

The chip name is no longer baked into `launch.json` and `tasks.json`:

- the SVD comes from `cmsis-core/download_files/SVD.svd` — downloaded for the
  chip in `project.json`;
- the executable is `${command:cmake.launchTargetPath}` (the active CMake
  target), the project name is not hardcoded;
- `preLaunchTask` is `CMake: Build` (the active preset);
- the ST-Link profiles (`ST-Link Launch` / `ST-Link Attach`) do not use a
  `device` field;
- in the OpenOCD profiles, the `target/<family>.cfg` file is picked from a
  list at launch (`stm32f4x`, `stm32g4x`, …); the path to the scripts comes
  from the OpenOCD installation;
- `cpuFrequency` in `swoConfig` is the core clock in Hz (not a chip name); set
  it to match your clock configuration.

## Important caveats and limitations

- The project depends on downloading files from GitHub during configure.
  Without network access, the first setup will not succeed if the needed
  files are not already present locally.
- In `CMakeLists.txt` the linker script comes from
  `cmsis-core/download_files/linker/`, so the final working configuration
  must be there.
- The template is geared toward CMSIS and the author's own drivers, not HAL/LL.
- The bootloader is still a skeleton: image check and jumping to the
  application are implemented, an update protocol is not (see `stm32-bootloader`).
- Drivers currently support only F4 / F7 / G0. For other families (G4, etc.)
  — use `"drivers": null`.
- The `src/main.cpp` demo is written for F4 (`RCC->AHB1ENR`, PA5); on other
  families you need to replace it with your own code.
- `main.cpp` currently uses direct register access, so the initial clock/init
  state depends on the MCU's reset state.
- Without a preset (`cmake -B ...` directly) there is no optimization — use `cmake --preset ...`.

## What to do right after cloning

- set your own `"device"` in `project.json`;
- check that `arm-none-eabi-*` are available from the console;
- run `cmake --preset debug`;
- make sure the needed startup/device/linker files were downloaded;
- pick a debug profile (`ST-Link` or OpenOCD) and, for SWO, set
  `cpuFrequency` in `.vscode/launch.json`;
- replace the demo `src/main.cpp` with your own application logic.

## Where to look first

If you want to get a quick feel for the project, start with these files:

- `project.json` — the whole project configuration.
- `CMakeLists.txt` — how config, platform, drivers, and the image fit together.
- `cmake/functions.cmake` — `stm32_read_config()`, `stm32_add_firmware()`, and the other functions.
- `cmake/cmsis-download.cmake` — where the startup/header/linker files come from.
- `src/main.cpp` — a minimal CMSIS example.
- `Drivers/src/*.hpp` — the available drivers and their API (described in `Drivers/ReadMe.md`).

## Summary

This repository is a convenient base for your own bare-metal `STM32`
projects, if you want to:

- build everything through `CMake`;
- not depend on CubeMX;
- use CMSIS and your own C++ drivers;
- have a ready-made start for building, flashing, and debugging in `VS Code`.

For the first run, the main thing is bringing `"device"` in `project.json`,
the startup/linker/SVD, and the debug configuration to the same microcontroller.

---

## Русский

Этот репозиторий представляет собой стартовый шаблон для bare-metal разработки под `STM32` на `C/C++` с использованием `CMake`, `arm-none-eabi-gcc`, `CMSIS` и набора собственных драйверов автора. Проект рассчитан на работу из `VS Code`, но не привязан к IDE и может собираться из командной строки.

Основная идея репозитория:

- быстро поднять новый проект под конкретный STM32 без CubeMX;
- генерировать линкерный скрипт под выбранный чип автоматически;
- подтягивать CMSIS/device/startup-файлы напрямую из внешнего репозитория.

Это именно база для старта прикладного приложения.

## Что внутри

На верхнем уровне находятся:

- `project.json` — **единственный файл конфигурации**: имя, версия, чип, heap/stack, список драйверов, исходники, include-пути, загрузчик (`bootloader`). Только данные, без кода.
- `CMakeLists.txt` — склейка: конфиг → тулчейн → `project()` → скачивание → таргет `stm32_platform` (флаги, не зависящие от конфигурации) → драйверы → `stm32_add_firmware()`. Правится редко.
- `CMakePresets.json` — пресеты `debug`, `debug-o0`, `release`, `relWithDebInfo`, `minSizeRel`. Здесь же **единственное место флагов оптимизации и отладки** (`-Og/-O0/-Os`, `-g*`, `NDEBUG`) — через `CMAKE_<C|CXX>_FLAGS_<CONFIG>`.
- `cmake/functions.cmake` — все функции платформы (чтение конфига, `stm32_add_firmware`, загрузка файлов), только определения.
- `cmake/cmsis-download.cmake` — процедурный, выполняется один раз: скачивание CMSIS/startup/векторов, разбор чипа, выбор шаблона линкер-скрипта. Только достаёт файлы и факты — флагов здесь нет.
- `cmake/toolchain.cmake` — выбор компилятора `arm-none-eabi-*`.
- `src/` — пользовательский код приложения (пример на CMSIS).
- `inc/` — пользовательские заголовки (`main.hpp` — закомментированные includes драйверов).
- `Drivers/` — библиотека `STM32_Drivers_CPP`; клонируется при первой конфигурации, если `"drivers"` включены (в `.gitignore`).
- `Bootloader/` — репозиторий загрузчика; клонируется, если в `project.json` задан `"bootloader"` (в `.gitignore`).
- `no_system_files/` — `syscalls.c` и `sysmem.c` для newlib/newlib-nano.
- `cmsis-core/` — локальная база CMSIS Core headers.
- `cmsis-core/download_files/` — скачанные startup/device/linker/SVD-файлы под выбранный MCU.
- `.vscode/` — готовые настройки задач, прошивки и отладки через ST-Link.

## Что делает проект при конфигурации

Во время `cmake configure` проект:

1. `stm32_read_config()` читает `project.json` в переменные `CFG_*` и проверяет их.
2. Берёт имя целевого микроконтроллера (`CFG_device`), определяет семейство, startup-файл, заголовки устройства и объёмы памяти.
3. Скачивает недостающие файлы из репозитория `STM32-base_files`:
   - `startup_common.c`
   - `vector_<device>.c`
   - device headers
   - `system_<series>.h`
   - `SVD`
   - шаблон linker script
4. В `CMakeLists.txt` создаётся таргет `stm32_platform` — все флаги компилятора и линкера в одном месте.
5. Если `"drivers"` не `null`/`false` — подключает `Drivers/` (первая конфигурация клонирует их).
6. Если задан `"bootloader"` — клонирует `Bootloader/` и собирает его первым образом `bootloader` в секторах `[0, N)`.
7. `stm32_add_firmware()` рендерит `.ld` под окно флеша образа и собирает `.elf/.hex/.bin/.dis` (для приложения с загрузчиком — с сектора `N`).

Драйверы генерируют `flash_config.h` / `irq_registry_config.h` сами (это их внутренние заголовки).

Под какой чип скачаны файлы, запоминает маркер `cmsis-core/download_files/.device`. Если `"device"` изменился (или файлы лежат без маркера), `cmake/cmsis-download.cmake` стирает скачанное и артефакты сборки и качает заново — даже после `rm -rf build`.

## Контракты runtime и сборки

### Каталоги для генерируемых файлов

`build/<preset>/`, `cmsis-core/download_files/` и `cmsis-core/drivers_gen/`
содержат только удаляемые артефакты сборки, скачанные и генерируемые файлы.
**Не храните в них свои исходники, заголовки и документы.** При смене MCU
или формата платформы содержимое удаляется; во время configure сохраняются
CMakeCache.txt/CMakeFiles. Пользовательский код храните в src/inc и указывайте
в project.json. Сборка внутри корня исходников и в его родительском каталоге запрещена.

Новый формат платформы — 2: startup, linker templates и maps обновляются
совместно. Старый набор downloaded/generated files обновляется один раз при
configure. Linker tables используют размеры в байтах и символы с префиксом
`__stm32_`, чтобы не конфликтовать с ABI стартапа CMSIS.

### Минимальный startup и FPU

Startup копирует и обнуляет RAM по таблицам линкера: .data/.bss, CCM, ITCM,
DTCM и SRAM2. Выставляет VTOR текущего образа, если регистр доступен, держит IRQ
выключенными при инициализации памяти и вызове конструкторов, затем включает
IRQ непосредственно перед main. Возврат из main заканчивается бесконечным циклом.

При `__FPU_PRESENT == 1` и `__FPU_USED == 1` startup разрешает доступ к
CP10/CP11 через `SCB->CPACR` после инициализации RAM. Одна общая пара `DSB`/`ISB`
завершает настройку FPU, VTOR и масок ядра перед вызовом конструкторов.
На устройствах и в сборках без аппаратного FPU
этот блок исключается. Поэтому глобальные/статические конструкторы могут
использовать float/double; доступ к FPU не зависит от вызова `System::Init()`
из main. Драйверы сохраняют включение FPU для работы с другими startup.
Платформа передаёт firmware и драйверам `STM32_STARTUP_ENABLES_FPU`, поэтому
`System::Init()` пропускает запись CPACR и барьеры, уже выполненные startup.
При замене startup уберите определение, если новый startup не включает FPU.
Базовая платформа не предоставляет отдельного API инициализации FPU.
При настроенном `bootloader` в project.json платформа также передаёт
`STM32_USE_BOOTLOADER` обоим образам и общей библиотеке драйверов. Макрос
включает отдельную функцию подготовки из `System::Init()` для F4/F7/G0:
HSI, делители /1, VOS Range 1 на G0 и Flash latency 0. Таймауты VOS/latency
остаются по 100 мс. Без макроса вызывайте `System::Init()` один раз после
аппаратного сброса, до настройки частот; код подготовки исключён из компиляции.
Конструкторы до main не должны ожидать работу через IRQ: прерывания ещё закрыты.
Vendor `system_stm32*.c`, SystemInit и глобальный CMSIS clock API не используются
и не скачиваются. `system_stm32*.h` сохраняется: его включают device headers.
Используйте `System::SystemCoreClock` с драйверами либо свой учёт частоты.

### Режимы банков Flash и зависимости

`flash_bank_mode` принимает `"single"` / `"dual"`. Отсутствие ключа/null выбирает
фиксированный режим у single-only/dual-only устройств; у переключаемых по
умолчанию single. Неподдерживаемый явный режим — ошибка конфигурации. Поэтому
F429ZI (2 MiB) автоматически использует два банка. База и драйвер используют одну
выбранную карту формата 3: адрес, размер, банк и аппаратный селектор стирания.

Столбец `FLASH_LAYOUT` таблицы устройств непосредственно выбирает общую геометрию.
Наличие карт стирания single/dual определяет допустимые режимы; отдельных таблиц
соответствий устройств и допустимых режимов нет.

Переключаемые F4 с 1 MiB используют DB1M, F76/F77 — nDBANK, G0B1/C1 с 256 КиБ —
DUAL_BANK. Flash-драйвер сверяет фактический режим при инициализации и возвращает
SysInitStatus::InitError при несовпадении или активном bank swap. Для фиксированных
режимов не читаются не относящиеся к ним биты. Option bytes задаёт пользователь;
после изменения нужен сброс МК. При отключённых драйверах приложение на CMSIS
само проверяет аппаратную конфигурацию.

У G4 category 3 размер страниц single — 4 КиБ, dual — 2 КиБ. В вариантах
128/256 КиБ dual между банками есть разрыв; банк 2 начинается с 0x08040000.
Обычный код, константы и начальные данные RAM размещаются в первом непрерывном
банке выбранного окна образа; `.flash_bank2` явно размещает const-данные или
функции в доступном втором банке. Linker исключает разрыв и ограничивает обе
области выбранным окном секторов. `app_start_sector` — логический индекс в карте
стирания, включая банк 2; он не равен аппаратному селектору.

```cpp
__attribute__((section(".flash_bank2"))) const uint32_t table[16] = {1, 2, 3};
```

Непрерывная Flash в single/dual использует обычную единую область `FLASH`.
Только для G4 с разрывом добавляются `FLASH_BANK2` и явная секция `.flash_bank2`.
ELF/HEX сохраняют адреса обеих областей. Обычная генерация BIN сохранена;
если данные есть в обеих областях, BIN содержит заполнение адресного разрыва.
Отдельный бинарный файл второго банка не генерируется.

В карты добавлены G0B0/B1/C1 и варианты L071/L072/L073 category 5. Поддержка
Flash-драйвера остаётся F4/F7/G0. Карты H7 обновлены (включая страницы H7A3/B3
по 8 КиБ), но linker/runtime платформы H7 остаётся отдельной задачей.

Обновляйте базу, драйверы и base_files совместно. Замените сохранённые
STM32-map.cmake, flash_config.h.in и linker-шаблон файлами этой версии base_files
либо задайте STM32_BASE_FILES_DIR с путём к её рабочей копии. Старые карты
формата 2 и старые flash_config-шаблоны отклоняются. Для уже скопированного
проекта нужно также обновить его cmake/*.cmake: изменение
исходных репозиториев само по себе не заменяет эти копии.

Каждый прочитанный project.json вызывает reconfigure при изменении.
Каждый сгенерированный .ld является зависимостью линковки: heap/stack применяются
обычной сборкой без clean rebuild. Debug presets определяют DEBUG для потребителей платформы.

При разработке с соседними репозиториями доступны локальные зависимости:

```powershell
cmake --preset debug -DSTM32_BASE_FILES_DIR=../STM32-base_files -DFETCHCONTENT_SOURCE_DIR_DRIVERS=../STM32_Drivers_CPP -DFETCHCONTENT_SOURCE_DIR_BOOTLOADER=../stm32-bootloader
```

Локальный base-files override отслеживает изменения файлов; удалённые файлы
сохраняются после первой загрузки. Для повторяемости коммитьте скачанные файлы
и выбирайте фиксированный tag/revision загрузчика. Согласованные изменения
платформы/base_files/bootloader/drivers должны быть доступны локально либо
опубликованы upstream до чистой конфигурации через сеть.

`bootloader.extra_sources: []` ничего не добавляет. Исходники самого загрузчика
собираются; проект предоставляет одну реализацию bl_stay, а не второй main.
Обновлённый загрузчик учитывает PWR F4/F7 и переносит VTOR; обновлённый startup
восстанавливает IRQ после перехода.

Для stdio определите `int __io_putchar(int)` и `int __io_getchar(void)`
(C linkage из C++) либо переопределите weak _write/_read. Без hooks возвращается
ENOSYS; ошибка вывода даёт EIO/short write; отрицательный ввод означает EOF.
Не вызывайте malloc/free из IRQ: поставляемая куча не предназначена для этого.

Описание изменений и проверок: [BASE_FIXES.md](BASE_FIXES.md).

## Для какого сценария подходит репозиторий

Репозиторий удобен, если вам нужен:

- bare-metal проект без HAL;
- контроль над startup/linker/CMSIS на уровне файлов;
- сборка через `CMake` и `Ninja`;
- работа в `VS Code` с `CMake Tools` и `cortex-debug`;
- база для собственной библиотеки драйверов.

## Пример приложения

Текущий `src/main.cpp` — минимальный пример на чистом CMSIS (без драйверов, `"drivers": null`):

- включает тактирование `GPIOA` (`RCC->AHB1ENR`);
- переводит `PA5` (светодиод Nucleo-F446RE) в output;
- бесконечно переключает его с программной задержкой.

Пример написан под F4; на другом семействе замените включение тактирования порта. Заголовок чипа подключается как `#include STM32_DEVICE_HEADER` (define задаёт платформа).

В коде оставлен закомментированный вариант на драйверах (`System::Init()`, `ClockSystem::CalcPLL(...)` + `ClockSystem::Init<clocks>()`, `System::Enable_CYCCNT()`, `NUCLEO_LED`); чтобы его включить, поставьте `"drivers": true` и раскомментируйте includes ядра драйверов в `inc/main.hpp`.

## Требования

Для работы с проектом нужны:

- `CMake` версии `3.24+`
- `Ninja`
- тулчейн `arm-none-eabi-gcc` в `PATH`
- `arm-none-eabi-g++`
- `arm-none-eabi-objcopy`
- `arm-none-eabi-objdump`
- `arm-none-eabi-size`
- `git`

Для прошивки и отладки дополнительно:

- `STM32CubeProgrammer` CLI (`STM32_Programmer_CLI.exe`)
- `ST-Link`
- при отладке из VS Code: расширение `cortex-debug`
- при работе с CMake в VS Code: расширение `ms-vscode.cmake-tools`

## Быстрый старт

### 1. Настройте проект

Всё в одном файле — `project.json`. Допускаются строки-комментарии, начинающиеся с `//` (как в JSONC; в VS Code файл уже привязан к режиму `jsonc`, поэтому подсветка не ругается). Хвостовые комментарии после значения не поддерживаются. Ниже — пример без комментариев:

```json
{
  "name":         "firmware",
  "version":      "3.2",
  "device":       "STM32F446RE",
  "flash_bank_mode": null,
  "heap":         "0x200",
  "stack":        "0x400",
  "drivers":      null,
  "dma_regions":  [],
  "sources":      ["src/main.cpp"],
  "include_dirs": ["inc"],
  "bootloader":   null
}
```

- `device` — полный код чипа (`STM32F446RE`, `STM32F429ZG`, `STM32F407VG`); должен совпадать с грамматикой, которую понимает `cmake/cmsis-download.cmake`.
- `drivers` — подключение библиотеки `STM32_Drivers_CPP`:
  - `null` / `false` / ключ отсутствует — драйверы не собираются вообще (голый CMSIS + свой код);
  - `true` или `[]` — только ядро (system / rcc / gpio / flash / irq_registry);
  - `["UART", "SPI", "DSP", ...]` — ядро + перечисленные опциональные модули (`UART`, `SPI`, `DMA`, `TIM`, `RTC`, `ADC`, `DAC`, `I2C`, `MODBUS`, `CONTAINERS`, `PID` — собственный ПИД-регулятор, `DSP` — подмножество CMSIS-DSP от Arm).

  Драйверы поддерживают STM32 **F4 / F7 / G0**. Для остальных семейств (в т.ч. G4) ставьте `null` и пишите под регистры сами, либо портируйте драйверы.
- `sources` / `include_dirs` — ваш код и include-пути.
- `bootloader` — `null` / ключа нет: без загрузчика, прошивка с начала флеша (никаких секторов). `{"app_start_sector": N, "repo": "...", "tag": "...", "extra_sources": [...]}` (`repo`/`tag`/`extra_sources` необязательны; `repo`/`tag` по умолчанию `vsm-stm/stm32-bootloader`, `main`): загрузчик в начале флеша (секторы `[0, N)`), прошивка — с сектора `N`. Платформа клонирует репозиторий в `Bootloader/` (как `Drivers/`) и собирает его **вторым образом** этим же проектом: берёт списки `sources` / `include_dirs` из его `project.json`; его `CMakeLists.txt` не используется. `stm32-bootloader` — маленькая библиотека (проверка образа, прыжок, флаг обновления), с собственным `main()` — `extra_sources` добавляет реализацию `bl_stay(bl_stay_reason_t)` и её transport/hardware код: файлы ЭТОГО проекта (пути от его `project.json`), которые добавляются к сборке образа загрузчика. `include_dirs` обоих проектов теперь общие в обе стороны: загрузчик видит `include_dirs` этого проекта, а этот проект — `include_dirs` загрузчика (обычно `Bootloader/src`, там — общие для обеих сторон заголовки вроде флага «нужно обновление»; ничего не копипастится). Каждый образ получает `STM32_IMAGE_FLASH_ORIGIN/END`. Образ, не влезший в свои сектора, — ошибка линковки (`region FLASH overflowed`). Прошивка с сектора `N > 0` сама не запустится: при сбросе ядро берёт вектор с `0x08000000` — его должен запускать загрузчик.

Автономный загрузчик (`stm32-bootloader`) скачивает файлы этой платформы (`cmake/`, `no_system_files/`, `cmsis-core/Include`) в своё дерево и запускает тот же сценарий; в его `project.json` верхний ключ `app_start_sector` задаёт `[0, N)`. Определение `STM32_DEVICE_HEADER` (`"stm32f4xx.h"`) позволяет коду без драйверов писать `#include STM32_DEVICE_HEADER`.

#### Некешируемые DMA-буферы (STM32F7)

`dma_regions` — необязательная настройка. Отсутствие ключа/null/`[]` ничего
не резервирует. Непустой список требует F7 и включённых драйверов (`true`, `[]`
или список модулей); на F4/G0 или без драйверов это ошибка конфигурации.
Поддерживается только внутренняя SRAM1/SRAM2:

```json
"dma_regions": [
  {"name": "adc", "size": "0x4000", "memory": "SRAM2", "mpu_region": 7}
]
```

Имена — уникальные идентификаторы. Размеры — степени двойки, не меньше 32 байт.
Номера MPU — уникальные в диапазоне 1..7; регион 0 зарезервирован. Адреса
вычисляются автоматически с конца выбранной памяти в порядке списка с выравниванием
по размеру каждой области. Отступы выравнивания тоже резервируются. Размещение
больших областей первыми может уменьшить потери памяти. Длина обычной RAM
уменьшается, включая верх stack в SRAM1 и доступное место `.sram2_bss` в SRAM2.
SRAM2 можно занять целиком; в SRAM1 должно остаться место для обычных данных/heap/stack.
Нехватка — ошибка конфигурации или линковки. Явный `address` и внешняя память
не поддерживаются.

```cpp
__attribute__((section(".dma.adc"))) static uint16_t adc_buffer[1024];
```

Поддерживаются только глобальные/static-буферы с нулевой инициализацией.
Секции NOLOAD обнуляются существующей таблицей startup до конструкторов.
Нельзя использовать ненулевые начальные значения или объекты с динамической
инициализацией: начальные данные из Flash не копируются. Ненастроенные секции
`.dma.*` вызывают ошибку линковки.

Вызывайте `System::Init()` до настройки периферии и запуска DMA. Он задаёт
указанным регионам MPU атрибуты Normal non-cacheable, shareable, чтение/запись,
запрет исполнения, затем включает D-cache. Если кеш уже включён, сначала
выключает его с clean/invalidate и сохранением изменённых данных. Остальные
регионы MPU остаются; исключите конфликты своих номеров и перекрытие регионами
с более высоким приоритетом. Конструкторы не должны запускать DMA; загрузчик
должен остановить свой DMA перед передачей управления. Обычные буферы
stack/heap/data остаются за пределами этих областей.

Нужны обновлённые **драйверы и base_files**. Конфигурация отклоняет старые
версии драйверов и F7 linker-шаблона. Для локальной разработки base_files задайте
`STM32_BASE_FILES_DIR` с путём к обновлённой рабочей копии; иначе обновите
сохранённый в проекте `cmsis-core/download_files/linker/linker-f7.ld.in`.
Приложение и загрузчик используют области из своих `project.json` независимо.
Подробности MPU/кеша — в `System.md` драйверов. Обслуживание кешируемых DMA-буферов
в остальных драйверах остаётся следующим этапом.

Флаги: не зависящие от конфигурации — в таргете `stm32_platform` в `CMakeLists.txt`; оптимизация и отладка — в `CMakePresets.json`. В `project.json` флагов нет.

### 2. Сконфигурируйте и соберите

Из корня репозитория:

```powershell
cmake --preset debug
cmake --build --preset debug
```

Для релизной сборки:

```powershell
cmake --preset release
cmake --build --preset release
```

Артефакты попадают в:

```text
build/<preset>/
```

После сборки автоматически создаются:

- `.elf`
- `.hex`
- `.bin`
- `.map`
- `.dis`

## Работа из VS Code

В репозитории уже подготовлены:

- `CMakePresets.json`
- `.vscode/tasks.json`
- `.vscode/launch.json`
- `.vscode/settings.json`

Что уже настроено:

- сборка через активный `CMake` preset (`CMake: Build`);
- прошивка приложения через `STM32_Programmer_CLI.exe` по `SWD` (`STM32Prog: Flash app (SWD)`) — прошивает активную launch target CMake; с загрузчиком сначала выберите приложение (не `bootloader`) в строке состояния CMake;
- прошивка загрузчика (`STM32Prog: Flash bootloader (SWD)`) и обоих образов подряд (`Build + Flash all`) — если в `project.json` задан `bootloader`;
- полное стирание чипа;
- отладка через `cortex-debug`: `ST-Link Launch` / `ST-Link Attach` (штатный GDB-сервер ST-Link), `ST-Link-OCD` / `ST-Link-OCD-SWO` (OpenOCD, семейство выбирается при запуске; SWO — вывод трассировки), `VS_Launch` (расширение ST для VS Code);
- использование локально скачанного `SVD` файла.

Кнопки в строке состояния (расширение «Task Buttons», `VsCodeTaskButtons.tasks` в `settings.json`) дублируют задачи, так что командная строка не нужна: `Configure`, `Build`, `Rebuild`, `Build+Flash`, `Flash all` (загрузчик + приложение), `Flash BL`, `Flash App`, `Reset`, `Erase`, `Probes`.

Для **отладки** (не прошивки) нужна цель CMake (`cmake.launchTargetPath`) — с загрузчиком целей две (`bootloader` и `firmware`), нужную выбирают в строке состояния CMake; см. ниже.

Типичный сценарий в VS Code:

1. Открыть папку проекта.
2. Выбрать configure preset, например `debug`.
3. Выполнить `CMake: Configure`.
4. Выполнить `CMake: Build`.
5. Запустить задачу `STM32Prog: Flash app (SWD)` или `Build + Flash` (с загрузчиком — `Build + Flash all`).
6. Для отладки выбрать конфигурацию из `launch.json` (см. выше).

Отладка приложения с загрузчиком: прошейте оба образа, выберите цель `firmware` и используйте `ST-Link Attach`. Запуск `ST-Link Launch` перепрошивает и сбрасывает ядро; приложение стартует только через загрузчик, который передаёт ему управление.

## Прошивка из командной строки

Если `STM32_Programmer_CLI.exe` доступен в `PATH`, можно прошивать так:

```powershell
STM32_Programmer_CLI.exe --connect port=swd --download build/debug/<project>.elf --start
```

С загрузчиком — сначала загрузчик, затем приложение (адреса зашиты в ELF):

```powershell
STM32_Programmer_CLI.exe --connect port=swd --download build/debug/bootloader.elf
STM32_Programmer_CLI.exe --connect port=swd --download build/debug/<project>.elf --start
```

Посмотреть доступные интерфейсы:

```powershell
STM32_Programmer_CLI.exe --list
```

Полное стирание:

```powershell
STM32_Programmer_CLI.exe --connect port=swd --erase all
```

## Как добавить свой код

Обычно достаточно:

1. Добавить `.cpp/.c` файлы в `src/`.
2. Добавить заголовки в `inc/`.
3. Дописать новые исходники в `"sources"` в `project.json`.
4. При необходимости добавить include-пути в `"include_dirs"`.
5. Нужные модули драйверов — в массив `"drivers"`.

## Как переключить проект на другой STM32

1. Измените `"device"` в `project.json`.
2. Переконфигурируйте проект: `cmake --preset debug`.
3. При необходимости удалите старый каталог `build/`, если в нём остались артефакты от другого чипа.
4. Для отладки через OpenOCD выберите семейство нового чипа при запуске профиля (см. ниже). Больше в `.vscode` ничего менять не нужно.

### Что в `.vscode` не зависит от чипа

Имя чипа в `launch.json` и `tasks.json` больше не зашито:

- SVD берётся из `cmsis-core/download_files/SVD.svd` — он скачивается под чип из `project.json`;
- исполняемый файл — `${command:cmake.launchTargetPath}` (активная цель CMake), имя проекта не прописано;
- `preLaunchTask` — `CMake: Build` (активный пресет);
- профили ST-Link (`ST-Link Launch` / `ST-Link Attach`) поле `device` не используют;
- в профилях OpenOCD файл `target/<семейство>.cfg` выбирается при запуске из списка (`stm32f4x`, `stm32g4x`, …); путь к скриптам берётся из установки OpenOCD;
- `cpuFrequency` в `swoConfig` — тактовая частота ядра в Гц (не имя чипа); задайте под вашу конфигурацию тактирования.

## Важные особенности и ограничения

- Проект зависит от загрузки файлов из GitHub во время конфигурации. Без доступа к сети первая настройка не пройдёт, если нужных файлов ещё нет локально.
- В `CMakeLists.txt` linker script берётся из `cmsis-core/download_files/linker/`, поэтому итоговая рабочая конфигурация должна находиться именно там.
- Шаблон ориентирован на CMSIS и собственные драйверы автора, а не на HAL/LL.
- Загрузчик пока каркас: проверка образа и прыжок в приложение реализованы, протокол обновления — нет (см. `stm32-bootloader`).
- Драйверы пока поддерживают только F4 / F7 / G0. Для других семейств (G4 и т.д.) — `"drivers": null`.
- Демо `src/main.cpp` написано под F4 (`RCC->AHB1ENR`, PA5); на других семействах его нужно заменить своим кодом.
- В `main.cpp` сейчас используется прямой доступ к регистрам, поэтому начальная частота/инициализация зависят от reset state MCU.
- Без пресета (`cmake -B ...` напрямую) оптимизации нет — используйте `cmake --preset ...`.

## Что стоит сделать сразу после клонирования

- задать свой `"device"` в `project.json`;
- проверить, что `arm-none-eabi-*` доступны из консоли;
- выполнить `cmake --preset debug`;
- убедиться, что нужные startup/device/linker-файлы скачались;
- выбрать профиль отладки (`ST-Link` или OpenOCD) и, для SWO, задать `cpuFrequency` в `.vscode/launch.json`;
- заменить демонстрационный `src/main.cpp` на свою прикладную логику.

## Куда смотреть в первую очередь

Если вы хотите быстро понять проект, начните с этих файлов:

- `project.json` — вся конфигурация проекта.
- `CMakeLists.txt` — как склеиваются конфиг, платформа, драйверы и образ.
- `cmake/functions.cmake` — `stm32_read_config()`, `stm32_add_firmware()` и прочие функции.
- `cmake/cmsis-download.cmake` — откуда берутся startup/header/linker-файлы.
- `src/main.cpp` — минимальный пример на CMSIS.
- `Drivers/src/*.hpp` — доступные драйверы и их API (описание — `Drivers/ReadMe.md`).

## Итог

Этот репозиторий — удобная база для собственных bare-metal проектов под `STM32`, если вы хотите:

- собирать всё через `CMake`;
- не зависеть от CubeMX;
- использовать CMSIS и собственные C++-драйверы;
- иметь готовый старт для сборки, прошивки и отладки в `VS Code`.

Для первого запуска главное — привести `"device"` в `project.json`, startup/linker/SVD и debug-конфигурацию к одному и тому же микроконтроллеру.
