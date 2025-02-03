DOCKER_IMAGE := nim-cross
SOURCE_FILE := nimscreen.nim
OUT_DIR := out
# Base flags: -d:release already enables a good amount of optimization.
# We add --opt:speed and --gcc.options.opt="-O3" for maximum performance.
BASE_NIMFLAGS := c -d:release --opt:speed --gcc.options.opt="-O3" -d:strip

# Build the Docker image.
build-docker:
	docker build -t {{DOCKER_IMAGE}} .

# Build for generic ARM.
arm:
	mkdir -p {{OUT_DIR}}
	docker run --rm -v "$(PWD)":/src {{DOCKER_IMAGE}} sh -c "export CC_arm=arm-linux-gnueabihf-gcc && nim {{BASE_NIMFLAGS}} --cpu:arm --os:linux --passC:'-flto' -o:{{OUT_DIR}}/nimscreen-arm {{SOURCE_FILE}}"

# Build for ARMv7 (with an extra gcc flag).
armv7:
	mkdir -p {{OUT_DIR}}
	docker run --rm -v "$(PWD)":/src {{DOCKER_IMAGE}} sh -c "export CC_arm=arm-linux-gnueabihf-gcc && nim {{BASE_NIMFLAGS}} --cpu:arm --os:linux --gcc.options.extras='-march=armv7-a' --passC:'-flto' -o:{{OUT_DIR}}/nimscreen-armv7 {{SOURCE_FILE}}"

# Build for AARCH64.
aarch64:
	mkdir -p {{OUT_DIR}}
	docker run --rm -v "$(PWD)":/src {{DOCKER_IMAGE}} sh -c "export CC_aarch64=aarch64-linux-gnu-gcc && nim {{BASE_NIMFLAGS}} --cpu:aarch64 --os:linux --passC:'-flto' -o:{{OUT_DIR}}/nimscreen-aarch64 {{SOURCE_FILE}}"

# Default recipe (build for generic ARM).
default: arm
