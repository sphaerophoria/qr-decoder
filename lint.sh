#!/usr/bin/env bash

set -ex

zig build --summary all
zig fmt src --check
zig build test --summary all

valgrind \
        --suppressions=./suppressions.valgrind \
        --leak-check=full \
        --track-origins=yes \
        --track-fds=yes \
        --error-exitcode=1 \
        ./zig-out/bin/qr-annotator \
                --input ./src/libqr/res/hello_world.gif

echo "Success"
