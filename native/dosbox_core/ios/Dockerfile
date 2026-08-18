# Build environment for the iOS core.
#
# mobaiapp/iosbox supplies the cross toolchain (clang targeting arm64-apple-ios,
# ld64.lld) and an iOS SDK mounted from the iosbox-sdk volume. It carries
# neither CMake (which SDL2 needs) nor the autotools DOSBox-X needs, so both go
# in here. Everything installed runs on the host as ordinary amd64 packages;
# nothing here targets iOS.
FROM mobaiapp/iosbox:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake ninja-build pkg-config file python3 \
        autoconf automake libtool make git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
