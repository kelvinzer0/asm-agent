#!/usr/bin/env bash
# ============================================================================
# install.sh — ASM-AGENT Installer
# ============================================================================
# Downloads prebuilt binary + VisiBox from GitHub releases.
# No build tools (NASM, etc.) required.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
#   bash install.sh                    # Download prebuilt to ./asm-agent + ./bin/visibox
#   bash install.sh --prefix=/usr/local  # Install to system path
#   bash install.sh --build            # Build from source instead (needs NASM)
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
VERSION="0.4.1"
REPO="kelvinzer0/asm-agent"
PREFIX="${PREFIX:-/usr/local}"
INSTALL_DIR="$(pwd)"
INSTALL_TO_SYSTEM=false
BUILD_FROM_SOURCE=false

VISIBOX_VERSION="0.3.0"

# --- Helpers ---
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

check_cmd() { command -v "$1" &>/dev/null; }

# --- Parse arguments ---
for arg in "$@"; do
    case "$arg" in
        --prefix=*)
            PREFIX="${arg#*=}"
            INSTALL_TO_SYSTEM=true
            ;;
        --build)
            BUILD_FROM_SOURCE=true
            ;;
        --help|-h)
            echo "Usage: bash install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (default)             Download prebuilt binary from GitHub Releases"
            echo "  --prefix=PATH         Install to PATH/bin/asm-agent (default: /usr/local)"
            echo "  --build               Build from source (requires NASM, binutils, make)"
            echo "  -h, --help            Show this help"
            exit 0
            ;;
        *)
            warn "Unknown argument: $arg"
            ;;
    esac
done

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       ASM-AGENT Installer v${VERSION}       ║"
echo "  ║   x86-64 NASM Autonomous AI Agent    ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# --- Verify x86_64 ---
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    fail "Unsupported architecture: $ARCH. asm-agent requires x86_64."
fi
ok "Architecture: x86_64"

# --- Verify curl ---
if ! check_cmd curl; then
    fail "curl is required. Install it first: sudo apt install curl"
fi
ok "curl available"

# ============================================================================
# Mode 1: Download prebuilt binary (default)
# ============================================================================
download_prebuilt() {
    local url="https://github.com/${REPO}/releases/download/v${VERSION}/asm-agent-x86_64-linux.tar.gz"
    local tmpdir
    tmpdir="$(mktemp -d)"

    info "Downloading asm-agent v${VERSION} prebuilt binary..."
    if ! curl -sLf "$url" -o "$tmpdir/asm-agent.tar.gz"; then
        rm -rf "$tmpdir"
        fail "Download failed. Check if release v${VERSION} exists at:
  https://github.com/${REPO}/releases/tag/v${VERSION}
  Or use --build to compile from source."
    fi

    info "Extracting..."
    tar xzf "$tmpdir/asm-agent.tar.gz" -C "$tmpdir"
    rm -f "$tmpdir/asm-agent.tar.gz"

    # Find the binary (tar may have a subdirectory or not)
    if [ -f "$tmpdir/asm-agent" ]; then
        :
    elif [ -f "$tmpdir/bin/asm-agent" ]; then
        # flatten
        mv "$tmpdir/bin/asm-agent" "$tmpdir/asm-agent"
        mv "$tmpdir/bin/visibox" "$tmpdir/visibox" 2>/dev/null || true
    fi

    if [ ! -f "$tmpdir/asm-agent" ]; then
        rm -rf "$tmpdir"
        fail "Binary not found in archive. Archive structure may have changed."
    fi

    chmod +x "$tmpdir/asm-agent"

    local size
    size=$(stat -c %s "$tmpdir/asm-agent" 2>/dev/null || stat -f %z "$tmpdir/asm-agent" 2>/dev/null || echo "?")
    ok "asm-agent: ${size} bytes"

    # VisiBox
    if [ -f "$tmpdir/visibox" ]; then
        chmod +x "$tmpdir/visibox"
        local vsize
        vsize=$(stat -c %s "$tmpdir/visibox" 2>/dev/null || stat -f %z "$tmpdir/visibox" 2>/dev/null || echo "?")
        ok "visibox: ${vsize} bytes"
        HAS_VISIBOX=true
        VISIBOX_SRC="$tmpdir/visibox"
    else
        warn "VisiBox not in release archive, downloading separately..."
        download_visibox "$tmpdir"
        HAS_VISIBOX=$?
        VISIBOX_SRC="$tmpdir/visibox"
    fi

    ASM_AGENT_SRC="$tmpdir/asm-agent"
    TMPDIR="$tmpdir"
}

download_visibox() {
    local dest="$1"
    local vurl="https://github.com/kelvinzer0/visibox/releases/download/v${VISIBOX_VERSION}/visibox-x86_64-linux-gnu.tar.gz"

    info "Downloading VisiBox v${VISIBOX_VERSION}..."
    if curl -sLf "$vurl" -o "$dest/visibox.tar.gz"; then
        tar xzf "$dest/visibox.tar.gz" -C "$dest/"
        rm -f "$dest/visibox.tar.gz"
        chmod +x "$dest/visibox" 2>/dev/null || true
        if [ -f "$dest/visibox" ]; then
            ok "visibox: downloaded"
            return 0
        fi
    fi
    warn "VisiBox download failed. Agent will use /bin/sh fallback."
    return 1
}

# ============================================================================
# Mode 2: Build from source (--build)
# ============================================================================
build_from_source() {
    info "Mode: build from source"
    check_cmd git || fail "git required for --build. Install: sudo apt install git"
    check_cmd make || fail "make required. Install: sudo apt install make"
    check_cmd nasm || fail "nasm required. Install: sudo apt install nasm"
    check_cmd ld   || fail "ld (binutils) required. Install: sudo apt install binutils"

    if [ -f "Makefile" ] && [ -d "src" ] && [ -d "include" ]; then
        ok "Found source in current directory"
        TMPDIR="$(pwd)"
    else
        info "Cloning repository..."
        TMPDIR="$(mktemp -d)"
        git clone --depth 1 "https://github.com/${REPO}.git" "$TMPDIR" || fail "git clone failed"
        ok "Cloned to $TMPDIR"
        cd "$TMPDIR"
    fi

    info "Building..."
    make || fail "Build failed"

    if [ ! -f "$TMPDIR/asm-agent" ]; then
        fail "Build succeeded but binary not found"
    fi

    ASM_AGENT_SRC="$TMPDIR/asm-agent"

    local size
    size=$(stat -c %s "$TMPDIR/asm-agent" 2>/dev/null || stat -f %z "$TMPDIR/asm-agent" 2>/dev/null || echo "?")
    ok "asm-agent: ${size} bytes (built from source)"

    if [ -f "$TMPDIR/bin/visibox" ]; then
        HAS_VISIBOX=true
        VISIBOX_SRC="$TMPDIR/bin/visibox"
        local vsize
        vsize=$(stat -c %s "$VISIBOX_SRC" 2>/dev/null || stat -f %z "$VISIBOX_SRC" 2>/dev/null || echo "?")
        ok "visibox: ${vsize} bytes"
    else
        HAS_VISIBOX=false
        warn "VisiBox not found. Agent will use /bin/sh fallback."
    fi
}

# ============================================================================
# Install binary to destination
# ============================================================================
install_binary() {
    if [ "$INSTALL_TO_SYSTEM" = false ]; then
        # Local install: copy to current directory
        cp "$ASM_AGENT_SRC" "${INSTALL_DIR}/asm-agent"
        chmod +x "${INSTALL_DIR}/asm-agent"
        ok "Installed: ${INSTALL_DIR}/asm-agent"

        if [ "$HAS_VISIBOX" = true ] && [ -f "$VISIBOX_SRC" ]; then
            mkdir -p "${INSTALL_DIR}/bin"
            cp "$VISIBOX_SRC" "${INSTALL_DIR}/bin/visibox"
            chmod +x "${INSTALL_DIR}/bin/visibox"
            ok "Installed: ${INSTALL_DIR}/bin/visibox"
        fi

        echo ""
        info "Run:  ${INSTALL_DIR}/asm-agent \"your task here\""
        return
    fi

    # System install
    local dest="$PREFIX/bin"
    sudo mkdir -p "$dest"
    sudo cp "$ASM_AGENT_SRC" "$dest/asm-agent"
    sudo chmod +x "$dest/asm-agent"
    ok "Installed: $dest/asm-agent"

    if [ "$HAS_VISIBOX" = true ] && [ -f "$VISIBOX_SRC" ]; then
        local vdest="$PREFIX/lib/asm-agent/bin"
        sudo mkdir -p "$vdest"
        sudo cp "$VISIBOX_SRC" "$vdest/visibox"
        sudo chmod +x "$vdest/visibox"
        ok "Installed: $vdest/visibox"

        echo ""
        info "VisiBox requires ./bin/visibox relative to working directory."
        info "Create symlink in your working directory:"
        info "  mkdir -p bin && ln -sf $vdest/visibox bin/visibox"
    fi

    echo ""
    info "Run:  asm-agent \"your task here\""
}

cleanup() {
    if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && [[ "$TMPDIR" == /tmp/* ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

# ============================================================================
# Main
# ============================================================================
main() {
    if [ "$BUILD_FROM_SOURCE" = true ]; then
        build_from_source
    else
        download_prebuilt
    fi

    install_binary

    echo -e "${BOLD}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║         Installation Complete!        ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${NC}"
}

main "$@"