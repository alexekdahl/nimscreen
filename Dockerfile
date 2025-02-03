# Use the official Nim image as a base.
FROM nimlang/nim:latest

# Install cross-compilers for ARM and AARCH64.
RUN apt-get update && apt-get install -y \
    gcc-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu \
 && rm -rf /var/lib/apt/lists/*

# Set the working directory (your Nim source should be here).
WORKDIR /src

# By default, just start a shell.
CMD ["bash"]
