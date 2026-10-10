ARG BUILDROOT_IMAGE=buildbrain-buildroot:local
FROM ${BUILDROOT_IMAGE}

# Build the CM762 kernel module with the same ARM EABI compiler used by linux-brain.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc-arm-linux-gnueabi \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
