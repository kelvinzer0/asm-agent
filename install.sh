#!/usr/bin/env bash
# ============================================================================
# install.sh — ASM-AGENT Installer
# ============================================================================
# Downloads prebuilt binary + VisiBox from GitHub releases.
# Installs to /usr/local/bin by default.
# Prompts for API key and optional config during installation.
# No build tools (NASM, etc.) required.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
#   curl -sSL ... | bash -s -- --api-key=sk-xxx
#   bash install.sh --build                # Build from source instead (needs NASM)
#   bash install.sh --prefix=/opt          # Custom prefix (installs to /opt/bin)
#   bash install.sh --skip-config          # Skip configuration prompts
# ============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# --- Config ---
REPO="kelvinzer0/asm-agent"
PREFIX="${PREFIX:-/usr/local}"
BUILD_FROM_SOURCE=false
SKIP_CONFIG=false
VISIBOX_VERSION="0.3.0"

# User-provided values (from flags or interactive prompts)
USER_API_KEY=""
USER_API_URL=""
USER_MODEL=""

# --- Defaults ---
DEFAULT_API_URL="https://router9.warunglakku.com/v1/chat/completions"
DEFAULT_MODEL="cf/@cf/meta/llama-3.1-8b-instruct-fp8-fast"

# Auto-detect latest release version
detect_latest_version() {
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    VERSION=$(curl -sLf "$api_url" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "")
    if [ -z "$VERSION" ]; then
        VERSION="0.6.1"  # fallback
    fi
}
detect_latest_version

# --- Helpers ---
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }
prompt() {
    local var_name="$1"
    local label="$2"
    local default_val="${3:-}"
    local hidden="${4:-false}"
    local input_val=""

    if [ "$hidden" = true ]; then
        # Hidden input (for API keys) — read without echo
        if [ -n "$default_val" ]; then
            printf "${BOLD}${DIM}%s${NC} [****]: " "$label" > /dev/tty
        else
            printf "${BOLD}%s${NC}: " "$label" > /dev/tty
        fi
        read -rs input_val < /dev/tty || true
        echo > /dev/tty  # newline after hidden input
    else
        if [ -n "$default_val" ]; then
            printf "${BOLD}${DIM}%s${NC} [${default_val}]: " "$label" > /dev/tty
        else
            printf "${BOLD}%s${NC}: " "$label" > /dev/tty
        fi
        read -r input_val < /dev/tty || true
    fi

    # Use default if empty
    if [ -z "$input_val" ] && [ -n "$default_val" ]; then
        input_val="$default_val"
    fi

    # Export to parent scope
    eval "$var_name=\"\$input_val\""
}

check_cmd() { command -v "$1" &>/dev/null; }

# --- Parse arguments ---
for arg in "$@"; do
    case "$arg" in
        --prefix=*)
            PREFIX="${arg#*=}"
            ;;
        --api-key=*)
            USER_API_KEY="${arg#*=}"
            ;;
        --api-url=*)
            USER_API_URL="${arg#*=}"
            # Auto-append /chat/completions if missing
            case "$USER_API_URL" in
                */chat/completions) ;;
                */v1)                  USER_API_URL="${USER_API_URL}/chat/completions" ;;
                */v1/)                 USER_API_URL="${USER_API_URL}chat/completions" ;;
                */)                    USER_API_URL="${USER_API_URL}chat/completions" ;;
                *)                     USER_API_URL="${USER_API_URL}/chat/completions" ;;
            esac
            ;;
        --model=*)
            USER_MODEL="${arg#*=}"
            ;;
        --build)
            BUILD_FROM_SOURCE=true
            ;;
        --skip-config)
            SKIP_CONFIG=true
            ;;
        --help|-h)
            echo "Usage: bash install.sh [OPTIONS]"
            echo ""
            echo "Installs asm-agent to \${PREFIX}/bin/ (default: /usr/local/bin)"
            echo ""
            echo "Options:"
            echo "  (default)                Interactive install with config prompts"
            echo "  --api-key=SK-XXX         Set API key (skip prompt)"
            echo "  --api-url=URL            Set API URL (auto-appends /chat/completions if missing)"
            echo "  --model=MODEL            Set model name (skip prompt)"
            echo "  --prefix=PATH            Install to PATH/bin/ (default: /usr/local)"
            echo "  --build                  Build from source (requires NASM, binutils, make)"
            echo "  --skip-config            Skip all configuration prompts"
            echo "  -h, --help               Show this help"
            echo ""
            echo "Environment variables (read at runtime, not stored):"
            echo "  ASM_AGENT_API_KEY        Your API key (or OPENAI_API_KEY)"
            echo ""
            echo "Examples:"
            echo "  curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash"
            echo "  curl -sSL ... | bash -s -- --api-key=sk-xxx --model=gpt-4o"
            echo "  bash install.sh --prefix=/opt --api-url=https://api.openai.com/v1"
            exit 0
            ;;
        *)
            warn "Unknown argument: $arg"
            ;;
    esac
done

# Derived paths
DEST_BIN="$PREFIX/bin"
DEST_LIB="$PREFIX/lib/asm-agent"
DEST_VB_BIN="$DEST_LIB/bin"
DEST_VB_CFG="$DEST_LIB/config"

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
printf "  ║       ASM-AGENT Installer v%-13s║\n" "${VERSION}"
echo "  ║   x86-64 NASM Autonomous AI Agent    ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# --- Verify x86_64 ---
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    fail "Unsupported architecture: $ARCH. asm-agent requires x86_64."
fi
ok "Architecture: x86_64"
info "Latest release: v${VERSION}"
info "Install prefix: $PREFIX"
info "Binary dest:   $DEST_BIN/asm-agent"

# --- Verify curl ---
if ! check_cmd curl; then
    fail "curl is required. Install it first: sudo apt install curl"
fi
ok "curl available"

# ============================================================================
# Interactive Configuration
# ============================================================================
configure() {
    echo ""
    echo -e "${BOLD}  ── Configuration ──────────────────────────${NC}"
    echo ""

    # If all values provided via flags, skip prompts
    if [ "$SKIP_CONFIG" = true ]; then
        info "Skipping configuration (--skip-config)"
        return
    fi

    if [ -n "$USER_API_KEY" ] && [ -n "$USER_API_URL" ] && [ -n "$USER_MODEL" ]; then
        ok "All config provided via flags"
        return
    fi

    # --- API Key (required) ---
    if [ -z "$USER_API_KEY" ]; then
        echo -e "${YELLOW}  ASM-AGENT needs an API key to call the LLM.${NC}"
        echo -e "${DIM}  This will be stored locally in ~/.asm-agent.env (not uploaded anywhere).${NC}"
        echo ""

        # Check if already set in environment
        local env_key=""
        if [ -n "${ASM_AGENT_API_KEY:-}" ]; then
            env_key="$ASM_AGENT_API_KEY"
        elif [ -n "${OPENAI_API_KEY:-}" ]; then
            env_key="$OPENAI_API_KEY"
        fi

        if [ -n "$env_key" ]; then
            prompt USER_API_KEY "  API key (detected from env)" "$env_key" true
        else
            prompt USER_API_KEY "  Enter your API key" "" true
        fi

        if [ -z "$USER_API_KEY" ]; then
            echo ""
            warn "No API key provided. You can set it later:"
            warn "  export ASM_AGENT_API_KEY=sk-your-key-here"
            warn "  asm-agent \"your task\""
        fi
    fi

    # --- API URL (optional) ---
    if [ -z "$USER_API_URL" ]; then
        echo ""
        prompt USER_API_URL "  API endpoint URL" "$DEFAULT_API_URL"
    fi
    # Auto-append /chat/completions if the user didn't provide the full path
    case "$USER_API_URL" in
        */chat/completions) ;;
        */v1)                  USER_API_URL="${USER_API_URL}/chat/completions" ;;
        */v1/)                 USER_API_URL="${USER_API_URL}chat/completions" ;;
        */)                   USER_API_URL="${USER_API_URL}chat/completions" ;;
        *)                    USER_API_URL="${USER_API_URL}/chat/completions" ;;
    esac

    # --- Model (optional) ---
    if [ -z "$USER_MODEL" ]; then
        echo ""
        prompt USER_MODEL "  Model name" "$DEFAULT_MODEL"
    fi

    echo ""
}

# ============================================================================
# Write .env file to ~/.asm-agent.env
# ============================================================================
write_env_file() {
    local env_path="${HOME}/.asm-agent.env"

    # Skip if no config to write
    if [ -z "$USER_API_KEY" ] && [ -z "$USER_API_URL" ] && [ -z "$USER_MODEL" ]; then
        return
    fi

    {
        echo "# ASM-AGENT Configuration"
        echo "# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Source this file before running:  source ${env_path}"
        echo ""

        if [ -n "$USER_API_KEY" ]; then
            echo "export ASM_AGENT_API_KEY=\"${USER_API_KEY}\""
        fi
        if [ -n "$USER_API_URL" ]; then
            echo "export ASM_AGENT_API_URL=\"${USER_API_URL}\""
        fi
        if [ -n "$USER_MODEL" ]; then
            echo "export ASM_AGENT_MODEL=\"${USER_MODEL}\""
        fi
    } > "$env_path"

    chmod 600 "$env_path"  # owner-only (API key is sensitive)
    ok "Config written: ${env_path}"
}

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

    # VisiBox (in tarball as bin/visibox)
    if [ -f "$tmpdir/bin/visibox" ]; then
        VISIBOX_SRC="$tmpdir/bin/visibox"
        HAS_VISIBOX=true
        local vsize
        vsize=$(stat -c %s "$VISIBOX_SRC" 2>/dev/null || stat -f %z "$VISIBOX_SRC" 2>/dev/null || echo "?")
        ok "visibox: ${vsize} bytes (from release)"
    else
        warn "VisiBox not in release archive, downloading separately..."
        download_visibox "$tmpdir"
        HAS_VISIBOX=$?
        VISIBOX_SRC="$tmpdir/visibox"
    fi

    # Config from tarball
    if [ -f "$tmpdir/config/visibox.conf" ]; then
        VISIBOX_CONF_SRC="$tmpdir/config/visibox.conf"
    fi

    ASM_AGENT_SRC="$tmpdir/asm-agent"
    _TMPDIR="$tmpdir"
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
    fail "VisiBox download failed. VisiBox is REQUIRED for asm-agent to work."
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
        _TMPDIR="$(pwd)"
    else
        info "Cloning repository..."
        _TMPDIR="$(mktemp -d)"
        git clone --depth 1 "https://github.com/${REPO}.git" "$_TMPDIR" || fail "git clone failed"
        ok "Cloned to $_TMPDIR"
        cd "$_TMPDIR"
    fi

    info "Building..."
    make || fail "Build failed"

    if [ ! -f "$_TMPDIR/asm-agent" ]; then
        fail "Build succeeded but binary not found"
    fi

    ASM_AGENT_SRC="$_TMPDIR/asm-agent"

    local size
    size=$(stat -c %s "$_TMPDIR/asm-agent" 2>/dev/null || stat -f %z "$_TMPDIR/asm-agent" 2>/dev/null || echo "?")
    ok "asm-agent: ${size} bytes (built from source)"

    if [ -f "$_TMPDIR/bin/visibox" ]; then
        HAS_VISIBOX=true
        VISIBOX_SRC="$_TMPDIR/bin/visibox"
        local vsize
        vsize=$(stat -c %s "$VISIBOX_SRC" 2>/dev/null || stat -f %z "$VISIBOX_SRC" 2>/dev/null || echo "?")
        ok "visibox: ${vsize} bytes"
    else
        HAS_VISIBOX=false
        fail "VisiBox not found. VisiBox is REQUIRED for asm-agent."
    fi
}

# ============================================================================
# Install binary to ${PREFIX}/bin
# ============================================================================
install_binary() {
    # --- 1. Copy binary ---
    mkdir -p "$DEST_BIN"
    cp "$ASM_AGENT_SRC" "$DEST_BIN/asm-agent"
    chmod +x "$DEST_BIN/asm-agent"
    ok "Installed: $DEST_BIN/asm-agent"

    # --- 2. Copy VisiBox ---
    if [ "$HAS_VISIBOX" = true ] && [ -f "$VISIBOX_SRC" ]; then
        mkdir -p "$DEST_VB_BIN"
        cp "$VISIBOX_SRC" "$DEST_VB_BIN/visibox"
        chmod +x "$DEST_VB_BIN/visibox"
        ok "Installed: $DEST_VB_BIN/visibox"
    fi

    # --- 3. Copy config ---
    mkdir -p "$DEST_VB_CFG"
    if [ -n "${VISIBOX_CONF_SRC:-}" ] && [ -f "$VISIBOX_CONF_SRC" ]; then
        cp "$VISIBOX_CONF_SRC" "$DEST_VB_CFG/visibox.conf"
    elif [ ! -f "$DEST_VB_CFG/visibox.conf" ]; then
        printf '# VisiBox Configuration\nMAX_OUTPUT_BYTES=65536\nMAX_OUTPUT_LINES=500\nCOMMAND_TIMEOUT=30\nWORKING_DIR=.\n' \
            > "$DEST_VB_CFG/visibox.conf"
    fi
    ok "Installed: $DEST_VB_CFG/visibox.conf"

    # --- 4. Write .env to ~/.asm-agent.env ---
    write_env_file

    # --- 5. Create asm-agent-run wrapper ---
    cat > "$DEST_BIN/asm-agent-run" << WRAPPER_EOF
#!/usr/bin/env bash
# asm-agent-run — auto-sources ~/.asm-agent.env, sets up visibox symlinks
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
[ -f "\$HOME/.asm-agent.env" ] && source "\$HOME/.asm-agent.env"
VB_BIN="$DEST_VB_BIN/visibox"
VB_CFG="$DEST_VB_CFG/visibox.conf"
if [ ! -f "./bin/visibox" ] && [ -f "\$VB_BIN" ]; then
    mkdir -p bin config
    ln -sf "\$VB_BIN" ./bin/visibox
    ln -sf "\$VB_CFG" ./config/visibox.conf
fi
exec "$DEST_BIN/asm-agent" "\$@"
WRAPPER_EOF
    chmod +x "$DEST_BIN/asm-agent-run"
    ok "Installed: $DEST_BIN/asm-agent-run (wrapper)"

    # --- 6. Print quick start ---
    echo ""
    echo -e "${BOLD}  ── Quick Start ─────────────────────────────${NC}"
    echo ""
    if [ -f "${HOME}/.asm-agent.env" ]; then
        echo -e "  ${GREEN}asm-agent-run${NC} ${GREEN}\"your task here\"${NC}"
        echo -e "  ${DIM}(auto-sources ~/.asm-agent.env + sets up visibox symlinks)${NC}"
    else
        echo -e "  ${GREEN}export${NC} ASM_AGENT_API_KEY=sk-your-key"
        echo -e "  ${GREEN}asm-agent-run${NC} ${GREEN}\"your task here\"${NC}"
    fi
    echo ""
}

cleanup() {
    if [ -n "${_TMPDIR:-}" ] && [ -d "$_TMPDIR" ] && [[ "$_TMPDIR" == /tmp/* ]]; then
        rm -rf "$_TMPDIR"
    fi
}
trap cleanup EXIT

# ============================================================================
# Main
# ============================================================================
main() {
    # Step 1: Interactive configuration prompts
    configure

    # Step 2: Download or build
    if [ "$BUILD_FROM_SOURCE" = true ]; then
        build_from_source
    else
        download_prebuilt
    fi

    # Step 3: Install files + write .env + create wrapper
    install_binary

    echo -e "${BOLD}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║         Installation Complete!        ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${NC}"
}

main "$@"