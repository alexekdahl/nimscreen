FROM debian:bookworm AS build

RUN apt-get update && apt-get install -y \
    build-essential \
    gcc-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu \
    gcc-mipsel-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY sesh.c .
