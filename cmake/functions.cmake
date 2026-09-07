# ============================================================================
# functions.cmake — fetch / cache primitives used by cmsis-download.cmake
# ============================================================================
#
#   download_one()          — pull one file from STM32-base_files, skip if
#                             already vendored
#   stm32_clean_build_dir() — recover cleanly from a chip switch
#   k_to_int()              — "128K" -> 128
#
# These are also visible to STM32_Drivers_CPP/CMakeLists.txt (functions are
# global once defined, and this file is include()d before add_subdirectory
# reaches Drivers/): the drivers generate their own flash_config.h /
# irq_registry_config.h and reuse download_one() / k_to_int() to do it.
# ============================================================================

# ---------------------------------------------------------------------------
# download_one(FILE_NAME BASE_DIR URL_DIR)
#
#   FILE_NAME — destination file name only, no path (e.g. "stm32f446xx.h")
#   BASE_DIR  — destination directory, created if missing
#   URL_DIR   — the file's path inside the STM32-base_files repo, e.g.
#               "Device/STM32F4xx/Include/stm32f446xx.h"
#
# Fetches BASE_DIR/FILE_NAME from STM32-base_files if it isn't already there.
#
# "Already there and non-empty" always wins and is never re-downloaded — this
# is deliberate, not just an optimisation. On the final/consuming project the
# whole download destination is meant to be committed to git (vendored, not
# gitignored), so "already there" normally means "vendored by an earlier
# configure", not "stale leftover". The one thing that should force a
# re-fetch — switching DEVICE — is handled by the caller deleting the whole
# download destination up front (see the device-change check in
# cmsis-download.cmake), not by this function guessing staleness per file.
# ---------------------------------------------------------------------------
function(download_one FILE_NAME BASE_DIR URL_DIR)
	set(DEST "${BASE_DIR}/${FILE_NAME}")
	set(URL  "https://raw.githubusercontent.com/vsm-stm/STM32-base_files/refs/heads/master/${URL_DIR}")

	message(STATUS "Downloading file: ${FILE_NAME}")

	# Skip re-downloading a file that's already vendored.
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

	# A 0-byte file usually means a 404 that file(DOWNLOAD) didn't treat as a
	# hard failure (e.g. a redirect to an HTML error page) — catch it here
	# rather than silently vendoring an empty header.
	file(SIZE "${DEST}" SZ)
	if(SZ EQUAL 0)
		file(REMOVE "${DEST}")
		message(FATAL_ERROR "Downloaded file is empty: ${URL}")
	endif()

	message(STATUS "Download complete! File: ${DEST}")
endfunction()

# ---------------------------------------------------------------------------
# stm32_clean_build_dir()
#
# Wipes everything in the current build directory except CMakeCache.txt and
# CMakeFiles/. Called when DEVICE changes mid-project (see
# cmsis-download.cmake), so the next build can't mix object files compiled
# for the old chip with headers/linker scripts generated for the new one.
#
# CMakeCache.txt and CMakeFiles/ are kept, not because something later reuses
# them, but because this function runs *during* the very configure pass that
# owns them — deleting them out from under a configure that's still in
# progress would break this run, not just leave stale files behind.
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
