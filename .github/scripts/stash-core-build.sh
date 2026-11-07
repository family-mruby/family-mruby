#!/bin/bash
# Copy what the installer stages from fmruby-core/build into $1 (run in fmruby-core).
set -euo pipefail
dest="$1"
mkdir -p "$dest/bootloader" "$dest/partition_table"
cp build/bootloader/bootloader.bin           "$dest/bootloader/"
cp build/partition_table/partition-table.bin "$dest/partition_table/"
cp build/fmruby-core.bin build/storage.bin   "$dest/"
# The staging script derives every flash offset from this file
cp build/flasher_args.json                   "$dest/"
