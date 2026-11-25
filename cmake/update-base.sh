#!/bin/sh
set -eu

main() {
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    update_dir=$(mktemp -d "${TMPDIR:-/tmp}/stm32-base-XXXXXXXX")
    keep_update_dir=no
    trap 'if [ "$keep_update_dir" = yes ]; then
        printf "Prepared update and backups kept at %s\n" "$update_dir"
    else
        rm -rf -- "$update_dir"
    fi' EXIT

    cmake -DUPDATE_ACTION=prepare "-DUPDATE_DIR=$update_dir" "-DTARGET_TAG=$1" \
        -P "$script_dir/update-base.cmake"
    [ -f "$update_dir/files.txt" ] || return 0

    printf 'Apply all listed changes? [y/N] '
    IFS= read -r answer || return 0
    case "$answer" in
        y|Y)
            keep_update_dir=yes
            cmake -DUPDATE_ACTION=apply "-DUPDATE_DIR=$update_dir" -P "$script_dir/update-base.cmake"
            keep_update_dir=no
            ;;
    esac
}

main "$@"
