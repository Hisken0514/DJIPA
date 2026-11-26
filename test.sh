#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
clang -Wall -Wextra -ISources/AudioCore/include Sources/AudioCore/AudioCore.c Sources/AudioCore/Effects.c Tests/process_test.c \
    -framework CoreAudio -o build/process_test
build/process_test
