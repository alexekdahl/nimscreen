DOCKER_IMAGE := nim-cross
SOURCE_FILE := nimscreen.nim
OUT_DIR := out
NIMFLAGS := c -d:release

# Recipe to build the Docker image.
build-docker:
	docker build -t {{DOCKER_IMAGE}} .

# Build for generic ARM.
arm:
	mkdir -p {{OUT_DIR}}
	docker run --rm -v "$(PWD)":/src {{DOCKER_IMAGE}} sh -c "export CC_arm=arm-linux-gnueabihf-gcc && nim {{NIMFLAGS}} --cpu:arm --os:linux -o:{{OUT_DIR}}/nimscreen-arm {{SOURCE_FILE}}"

# Build for ARMv7 (by adding an extra gcc flag).
armv7:
	mkdir -p {{OUT_DIR}}
	docker run --rm -v "$(PWD)":/src {{DOCKER_IMAGE}} sh -c "export CC_arm=arm-linux-gnueabihf-gcc && nim {{NIMFLAGS}} --cpu:arm --os:linux --gcc.options.extras='-march=armv7-a' -o:{{OUT_DIR}}/nimscreen-armv7 {{SOURCE_FILE}}"

# Build for AARCH64.
aarch64:
	mkdir -p {{OUT_DIR}}
	docker run --rm -v "$(PWD)":/src {{DOCKER_IMAGE}} sh -c "export CC_aarch64=aarch64-linux-gnu-gcc && nim {{NIMFLAGS}} --cpu:aarch64 --os:linux -o:{{OUT_DIR}}/nimscreen-aarch64 {{SOURCE_FILE}}"

# Default recipe (build for ARM).
default: arm
