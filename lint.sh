#!/usr/bin/env bash

set -ex

zig build --summary all
zig fmt src --check
zig build test --summary all

valgrind \
        --suppressions=./res/suppressions.valgrind \
        --leak-check=full \
        --track-origins=yes \
        --track-fds=yes \
        --error-exitcode=1 \
        ./zig-out/bin/qr-decoder \
                --input ./res/hello_world.gif

echo "Success"
