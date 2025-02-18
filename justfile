# Cross-compile targets
armv7:
    @docker build -t build .
    docker run -v "{{ justfile_directory() }}:/src" -w "/src" build arm-linux-gnueabihf-gcc -static -o bin/nimt-armv7 src/nimt.c -lutil

aarch64:
    @docker build -t build .
    docker run -v "{{ justfile_directory() }}:/src" -w "/src" build aarch64-linux-gnu-gcc -static -o bin/nimt-aarch64 src/nimt.c -lutil

mipsle:
    @docker build -t build .
    docker run -v "{{ justfile_directory() }}:/src" -w "/src" build mipsel-linux-gnu-gcc -static -o bin/nimt-mipsle src/nimt.c -lutil

all: armv7 aarch64 mipsle

