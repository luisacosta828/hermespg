# Multi-stage Dockerfile for HermesPG (Static Build on Scratch)
# Produces an ultra-lightweight, zero-overhead container image (~1.5 - 2.5 MB)

# --- Stage 1: Build static binary with Nim & Musl ---
FROM nimlang/nim:2.0.12-alpine AS builder

RUN apk add --no-cache gcc musl-dev git ca-certificates

# Create unprivileged runtime user and group for scratch runtime
RUN addgroup -g 10001 -S hermespg && \
    adduser -u 10001 -S -G hermespg -H -s /sbin/nologin hermespg

WORKDIR /app

# Copy dependency definition and install dependencies
COPY hermespg.nimble ./
RUN nimble install -y --depsOnly

# Copy source code and config
COPY config.nims ./
COPY src/ ./src/

# Compile with aggressive optimizations:
# -d:danger: Disables all runtime assertions and stack traces for max throughput
# --opt:speed: Maximum GCC optimization (-O3)
# -flto: Link-Time Optimization across all compilation units
# -ffunction-sections -fdata-sections -Wl,--gc-sections: Discard unused functions and variables
# -static: Fully static ELF binary (no dynamic glibc/musl runtime dependencies)
# -s: Strip all debug symbols for minimal binary size
RUN nim c -d:danger --opt:speed \
    --passC:"-flto -fomit-frame-pointer -ffunction-sections -fdata-sections" \
    --passL:"-flto -static -s -Wl,--gc-sections" \
    -o:/app/hermespg src/hermespg.nim

# --- Stage 2: Minimal scratch runtime ---
FROM scratch

# Metadata labels (OCI specification)
LABEL org.opencontainers.image.title="HermesPG" \
      org.opencontainers.image.description="Ultra-fast, lightweight PostgreSQL connection pooler and proxy in Nim" \
      org.opencontainers.image.url="https://github.com/luisacosta828/hermespg" \
      org.opencontainers.image.source="https://github.com/luisacosta828/hermespg" \
      org.opencontainers.image.licenses="MIT"

# Copy passwd, group and CA certs for non-root execution
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# Copy only the compiled static binary
COPY --from=builder /app/hermespg /hermespg

# Run as unprivileged user
USER 10001:10001

# Ports:
# 6432: PostgreSQL Connection Pooler / Proxy
# 9127: Prometheus Metrics Exporter
EXPOSE 6432 9127

# Run HermesPG directly as PID 1
ENTRYPOINT ["/hermespg"]
