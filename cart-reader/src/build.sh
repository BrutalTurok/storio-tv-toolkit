#!/bin/sh
# Builds cart_reader (static ARM executable, no libc) with clang/lld.
# For the PC test build (see ../README.md) use the same flags plus -DTEST.
set -e
cd "$(dirname "$0")"
CFLAGS="--target=armv7a-linux-gnueabi -marm -march=armv7-a -mfloat-abi=soft -O2 -ffreestanding -fno-builtin \
  -nostdlib -static -fno-pie -fuse-ld=lld -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
  -Wl,--gc-sections"
clang $CFLAGS cart_reader.c aeabi_int.c -o cart_reader
llvm-strip cart_reader
echo "Built $(pwd)/cart_reader"
