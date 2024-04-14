#!/usr/bin/env bash

set -ex

zig build --summary all
zig fmt src --check
zig build test --summary all

echo "Success"
