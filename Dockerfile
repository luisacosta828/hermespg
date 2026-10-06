# Multi-stage Dockerfile for HermesPG (Static Build on Scratch)
# Produces an ultra-lightweight, zero-overhead container image (~1.5 - 2.5 MB)

# --- Stage 1: Build static binary with Nim & Musl ---
FROM nimlang/nim:2.0.12-alpine AS builder

RUN apk add --no-cache gcc musl-dev git

WORKDIR /app

# Copy project manifest and configuration
COPY config.nims hermespg.nimble ./
COPY src/ ./src/

# Compile with aggressive optimizations:
# -d:danger: Disables all runtime assertions and stack traces for max throughput
# --opt:speed: Maximum GCC optimization (-O3)
# -flto: Link-Time Optimization across all compilation units
# -ffunction-sections -fdata-sections -Wl,--gc-sections: Discard unused functions and variables
# -static: Fully static ELF binary (no dynamic glibc/musl runtime dependencies)
# -s: Strip all debug symbols for minimal binary size
RUN nim c -d:danger --opt:speed --passC:"-flto -fomit-frame-pointer -ffunction-sections -fdata-sections" --passL:"-flto -static -s -Wl,--gc-sections" -o:/app/hermespg src/hermespg.nim

# --- Stage 2: Minimal scratch runtime ---
FROM scratch

# Copy only the compiled static binary
COPY --from=builder /app/hermespg /hermespg

# Default PostgreSQL connection pooler port
EXPOSE 6432

# Run HermesPG directly as PID 1
ENTRYPOINT ["/hermespg"]
