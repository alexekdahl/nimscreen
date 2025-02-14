BASE_NIMFLAGS := "-d:release --opt:speed -d:strip"

build:
    nim c {{ BASE_NIMFLAGS }}  --out:bin/nimscreen src/nimscreen.nim

run *args: build
    ./bin/nimscreen {{ args }}
