#!/usr/bin/env bash
# ==============================================================================
# HermesPG - Official Installer Script
# Ultra-fast PostgreSQL Connection Pooler & Proxy in Nim
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/luisacosta828/hermespg/main/install.sh | bash
#
# Options (via environment variables):
#   HERMESPG_VERSION   Target version (e.g. "v0.4.0", default: latest release)
#   INSTALL_DIR        Target binary directory (default: /usr/local/bin or ~/.local/bin)
# ==============================================================================

set -euo pipefail

GITHUB_REPO="luisacosta828/hermespg"
DEFAULT_FALLBACK_VERSION="v0.4.0"

# Color helpers
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[0;32m"
    CYAN="\033[0;36m"
    YELLOW="\033[0;33m"
    RED="\033[0;31m"
    RESET="\033[0m"
else
    BOLD=""
    GREEN=""
    CYAN=""
    YELLOW=""
    RED=""
    RESET=""
fi

info() {
    printf "${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$1"
}

success() {
    printf "${GREEN}==>${RESET} ${BOLD}%s${RESET}\n" "$1"
}

warn() {
    printf "${YELLOW}WARNING:${RESET} %s\n" "$1"
}

error() {
    printf "${RED}ERROR:${RESET} %s\n" "$1" >&2
    exit 1
}

# 1. Detect Operating System
detect_os() {
    local os
    os="$(uname -s)"
    case "$os" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        *)
            error "Unsupported Operating System: '$os'. HermesPG binaries are currently supported on Linux and macOS. Please build from source using Nim or use the Docker image (ghcr.io/${GITHUB_REPO}:latest)."
            ;;
    esac
}

# 2. Detect CPU Architecture
detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *)
            error "Unsupported Architecture: '$arch'. HermesPG binaries are built for amd64 (x86_64) and arm64 (aarch64)."
            ;;
    esac
}

# 3. Determine Version
determine_version() {
    if [ -n "${HERMESPG_VERSION:-}" ]; then
        echo "${HERMESPG_VERSION}"
        return
    fi

    local latest_tag=""
    if command -v curl >/dev/null 2>&1; then
        latest_tag=$(curl -sSL -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
            | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 || true)
    fi

    if [ -n "$latest_tag" ]; then
        echo "$latest_tag"
    else
        echo "$DEFAULT_FALLBACK_VERSION"
    fi
}

# 4. Determine Destination Directory
determine_install_dir() {
    if [ -n "${INSTALL_DIR:-}" ]; then
        echo "${INSTALL_DIR}"
        return
    fi

    if [ -w "/usr/local/bin" ] || [ "$(id -u)" -eq 0 ]; then
        echo "/usr/local/bin"
    elif [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
        echo "$HOME/.local/bin"
    else
        mkdir -p "$HOME/.local/bin" 2>/dev/null || true
        if [ -w "$HOME/.local/bin" ]; then
            echo "$HOME/.local/bin"
        else
            echo "/usr/local/bin"
        fi
    fi
}

main() {
    printf "\n"
    printf "${CYAN}╔════════════════════════════════════════════════════════════════╗${RESET}\n"
    printf "${CYAN}║${RESET}  ${BOLD}⚡ HermesPG Official Installer${RESET}                               ${CYAN}║${RESET}\n"
    printf "${CYAN}║${RESET}  Ultra-fast, zero-overhead PostgreSQL Connection Pooler        ${CYAN}║${RESET}\n"
    printf "${CYAN}╚════════════════════════════════════════════════════════════════╝${RESET}\n"
    printf "\n"

    local os arch version install_dir
    os="$(detect_os)"
    arch="$(detect_arch)"
    version="$(determine_version)"
    install_dir="$(determine_install_dir)"

    info "Detected platform: ${os}/${arch}"
    info "Target version:    ${version}"
    info "Install directory: ${install_dir}"

    local binary_name="hermespg-${os}-${arch}"
    local download_base="https://github.com/${GITHUB_REPO}/releases/download/${version}"
    local binary_url="${download_base}/${binary_name}"
    local checksum_url="${download_base}/SHA256SUMS.txt"

    local tmpdir
    tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t 'hermespg-install')"
    trap 'rm -rf "${tmpdir}"' EXIT

    info "Downloading ${binary_name} from GitHub..."
    if ! curl -fSL --progress-bar "${binary_url}" -o "${tmpdir}/${binary_name}"; then
        error "Failed to download binary from: ${binary_url}. Check if release ${version} exists."
    fi

    # Checksum validation if SHA256SUMS.txt is available
    info "Verifying cryptographic checksum..."
    if curl -fsSL "${checksum_url}" -o "${tmpdir}/SHA256SUMS.txt" 2>/dev/null; then
        local expected_sha=""
        expected_sha=$(grep "${binary_name}" "${tmpdir}/SHA256SUMS.txt" | awk '{print $1}' || true)

        if [ -n "$expected_sha" ]; then
            local computed_sha=""
            if command -v sha256sum >/dev/null 2>&1; then
                computed_sha=$(sha256sum "${tmpdir}/${binary_name}" | awk '{print $1}')
            elif command -v shasum >/dev/null 2>&1; then
                computed_sha=$(shasum -a 256 "${tmpdir}/${binary_name}" | awk '{print $1}')
            fi

            if [ -n "$computed_sha" ]; then
                if [ "$expected_sha" != "$computed_sha" ]; then
                    error "Checksum mismatch!\nExpected: ${expected_sha}\nComputed: ${computed_sha}"
                fi
                info "Checksum verified: ${computed_sha:0:16}..."
            fi
        fi
    else
        warn "Checksum file not found for ${version}; continuing without checksum verification."
    fi

    chmod +x "${tmpdir}/${binary_name}"

    # Install to target directory
    local dest="${install_dir}/hermespg"
    info "Installing binary to ${dest}..."

    mkdir -p "${install_dir}" 2>/dev/null || true

    if [ -w "${install_dir}" ]; then
        mv "${tmpdir}/${binary_name}" "${dest}"
    else
        info "Elevated permissions required for ${install_dir}. Requesting sudo..."
        if command -v sudo >/dev/null 2>&1; then
            sudo mv "${tmpdir}/${binary_name}" "${dest}"
            sudo chmod +x "${dest}"
        else
            error "Cannot write to ${install_dir} and sudo is not installed."
        fi
    fi

    # Verify installation
    if command -v "${dest}" >/dev/null 2>&1 || [ -x "${dest}" ]; then
        printf "\n"
        success "HermesPG installed successfully to ${dest}!"
        printf "\n"
        "${dest}" --version 2>/dev/null || true
        printf "\n"
    else
        error "Installation failed: ${dest} is not executable."
    fi

    # Check if PATH contains install_dir
    case ":${PATH}:" in
        *":${install_dir}:"*) ;;
        *)
            warn "${install_dir} is not in your \$PATH."
            printf "   Add it by running:\n"
            printf "   export PATH=\"%s:\$PATH\"\n\n" "${install_dir}"
            ;;
    esac

    printf "${BOLD}Quick Start:${RESET}\n"
    printf "  Start proxy with default settings:\n"
    printf "    ${CYAN}hermespg${RESET}\n\n"
    printf "  Connect to a remote PostgreSQL database:\n"
    printf "    ${CYAN}hermespg -H <db-host> -P 5432 -U <user> -W <pass> -d <dbname> -c 20${RESET}\n\n"
    printf "  See full documentation and flags:\n"
    printf "    ${CYAN}hermespg --help${RESET}\n\n"
}

main "$@"
