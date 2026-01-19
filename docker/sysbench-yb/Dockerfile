# YugabyteDB fork of sysbench
# Includes YugabyteDB-specific options like range_key_partitioning, serial_cache_size, etc.

FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    make \
    automake \
    autoconf \
    libtool \
    pkg-config \
    gcc \
    libpq-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone sysbench fork with YugabyteDB-specific options
WORKDIR /build
RUN git clone --depth 1 --branch master https://github.com/rophy/sysbench.git

# Build sysbench
WORKDIR /build/sysbench
RUN ./autogen.sh \
    && ./configure --with-pgsql --without-mysql \
    && make -j$(nproc) \
    && make install DESTDIR=/install

# Runtime image
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy sysbench from builder
COPY --from=builder /install/usr/local /usr/local

# Verify installation
RUN sysbench --version

# Set working directory
WORKDIR /sysbench

# Default command
CMD ["sleep", "infinity"]
