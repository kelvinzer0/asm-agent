#!/usr/bin/env bash
# ============================================================================
# install.sh — ASM-AGENT Installer
# ============================================================================
# Installs build dependencies (NASM, binutils, curl) and builds asm-agent.
# Supports: Debian/Ubuntu, Fedora/RHEL, Arch, Alpine.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/main/install.sh | bash
#   bash install.sh              # Install deps + build
#   bash install.sh --build-only # Skip dependency installation
#   bash install.sh --prefix=/usr/local  # Install to system path
# ============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Config ---
PREFIX="${PREFIX:-/usr/local}"
BUILD_ONLY=false
REPO_URL="https://github.com/kelvinzer0/asm-agent.git"
CLONE_DIR=""
INSTALL_TO_SYSTEM=false

# --- Helpers ---
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

check_cmd() {
    command -v "$1" &>/dev/null
}

# --- Parse arguments ---
for arg in "$@"; do
    case "$arg" in
        --build-only)
            BUILD_ONLY=true
            ;;
        --prefix=*)
            PREFIX="${arg#*=}"
            INSTALL_TO_SYSTEM=true
            ;;
        --help|-h)
            echo "Usage: bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --build-only         Skip dependency installation, just build"
            echo "  --prefix=PATH        Install binary to PATH/bin (default: /usr/local)"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            warn "Unknown argument: $arg"
            ;;
    esac
done

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       ASM-AGENT Installer v0.4.0      ║"
echo "  ║   x86-64 NASM Autonomous AI Agent    ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# --- Detect architecture ---
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    fail "Unsupported architecture: $ARCH. asm-agent requires x86_64."
fi
ok "Architecture: x86_64"

# --- Detect OS ---
detect_pkg_manager() {
    if check_cmd apt-get; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
    elif check_cmd dnf; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update -q"
    elif check_cmd pacman; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy --noconfirm"
    elif check_cmd apk; then
        PKG_MANAGER="apk"
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
    else
        PKG_MANAGER="unknown"
    fi
}

install_deps() {
    info "Detecting package manager..."
    detect_pkg_manager

    case "$PKG_MANAGER" in
        apt)
            info "Updating package list..."
            sudo $PKG_UPDATE
            info "Installing nasm, binutils, curl, make..."
            sudo $PKG_INSTALL nasm binutils curl make git
            ;;
        dnf)
            info "Installing nasm, binutils, curl, make, git..."
            sudo $PKG_INSTALL nasm binutils curl make git
            ;;
        pacman)
            info "Installing nasm, binutils, curl, make, git..."
            sudo $PKG_INSTALL nasm binutils curl make git
            ;;
        apk)
            info "Installing nasm, binutils, curl, make, git..."
            sudo $PKG_INSTALL nasm binutils curl make git musl-dev
            ;;
        *)
            warn "Could not detect package manager. Please install manually:"
            warn "  nasm, binutils (ld), curl, make, git"
            warn ""
            read -p "Continue anyway? [y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
            ;;
    esac
}

verify_deps() {
    local missing=()

    for cmd in nasm ld curl make git; do
        if ! check_cmd "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        fail "Missing dependencies: ${missing[*]}. Run without --build-only to install them."
    fi

    ok "All dependencies available"
}

# --- Clone or use existing repo ---
setup_repo() {
    if [ -f "Makefile" ] && [ -d "src" ] && [ -d "include" ]; then
        ok "Found asm-agent source in current directory"
        CLONE_DIR="$(pwd)"
        return
    fi

    info "Cloning asm-agent repository..."
    CLONE_DIR="$(mktemp -d)"
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR" || fail "Failed to clone repository"
    ok "Cloned to $CLONE_DIR"
}

# --- Build ---
build_agent() {
    cd "$CLONE_DIR"

    info "Building asm-agent..."
    if make; then
        ok "Build successful"
    else
        fail "Build failed. Check the error messages above."
    fi

    # Verify binary
    if [ -f "./asm-agent" ]; then
        local size
        size=$(stat -c %s ./asm-agent 2>/dev/null || stat -f %z ./asm-agent 2>/dev/null || echo "unknown")
        ok "Binary: ./asm-agent (${size} bytes)"
    else
        fail "Binary not found after build"
    fi

    # Check VisiBox
    if [ -f "./bin/visibox" ]; then
        local vsize
        vsize=$(stat -c %s ./bin/visibox 2>/dev/null || stat -f %z ./bin/visibox 2>/dev/null || echo "unknown")
        ok "VisiBox: ./bin/visibox (${vsize} bytes)"
    else
        warn "VisiBox not found (commands will use /bin/sh fallback)"
    fi
}

# --- Install ---
install_binary() {
    if [ "$INSTALL_TO_SYSTEM" = false ]; then
        echo ""
        info "Binary is ready at: $CLONE_DIR/asm-agent"
        info "Run: cd $CLONE_DIR && ./asm-agent"
        info "Or copy it: cp $CLONE_DIR/asm-agent /usr/local/bin/"
        return
    fi

    local dest="$PREFIX/bin"
    info "Installing to $dest/..."

    sudo mkdir -p "$dest"
    sudo cp "$CLONE_DIR/asm-agent" "$dest/asm-agent"
    sudo chmod +x "$dest/asm-agent"

    # Copy VisiBox alongside the binary
    local vdest="$PREFIX/lib/asm-agent"
    if [ -f "$CLONE_DIR/bin/visibox" ]; then
        sudo mkdir -p "$vdest"
        sudo cp "$CLONE_DIR/bin/visibox" "$vdest/visibox"
        sudo chmod +x "$vdest/visibox"
        warn "VisiBox installed to $vdest/visibox"
        warn "Note: asm-agent expects visibox at ./bin/visibox (relative path)"
        warn "To use VisiBox, run asm-agent from a directory containing bin/visibox"
    fi

    ok "Installed: $dest/asm-agent"
    echo ""
    info "Try: asm-agent \"List all files in /tmp\""
}

# --- Main ---
main() {
    if [ "$BUILD_ONLY" = false ]; then
        install_deps
    else
        info "Skipping dependency installation (--build-only)"
    fi

    verify_deps
    setup_repo
    build_agent
    install_binary

    echo -e "${BOLD}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║         Installation Complete!        ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${NC}"
}

main "$@"