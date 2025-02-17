BASE_NIMFLAGS := "-d:release --opt:speed -d:strip"

# Cross-compile targets
armv7:
    docker run --rm -v {{ justfile_directory() }}:/src -w /src build arm-linux-gnueabihf-gcc -static -o sesh-armv7 sesh.c -lutil

aarch64:
    docker run --rm -v {{ justfile_directory() }}/src -w /src build aarch64-linux-gnu-gcc -static -o sesh-aarch64 sesh.c -lutil

mipsle:
    docker run --rm -v {{ justfile_directory() }}:/src -w /src build mipsel-linux-gnu-gcc -static -o sesh-mipsle sesh.c -lutil

all: armv7 aarch64 mipsle

build:
    nim c {{ BASE_NIMFLAGS }}  --out:bin/nimscreen src/nimscreen.nim

run *args: build
    ./bin/nimscreen {{ args }}
