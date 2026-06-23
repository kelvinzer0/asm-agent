#!/bin/bash
# ============================================================================
# install.sh — One-liner installer for asm-agent
# ============================================================================
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
#
# Or with a specific version:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash -s -- --version v0.1.1
#
# Or with a custom install prefix:
#   curl -sSL ... | bash -s -- --prefix /usr/local
# ============================================================================
set -euo pipefail

# --- Defaults ---
INSTALL_PREFIX="/usr/local"
REPO_OWNER="kelvinzer0"
REPO_NAME="asm-agent"
BINARY_NAME="asm-agent"
VERSION=""
GITHUB_API="https://api.github.com"

# --- Colors (disable if not a terminal) ---
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

info()  { echo -e "${CYAN}  [INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}  [OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $*"; }
fail()  { echo -e "${RED}  [ERROR]${NC} $*" >&2; exit 1; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --version|-v)
      VERSION="$2"
      shift 2
      ;;
    --prefix|-p)
      INSTALL_PREFIX="$2"
      shift 2
      ;;
    --help|-h)
      echo "asm-agent installer"
      echo ""
      echo "Usage: curl -sSL <this-url> | bash [options]"
      echo ""
      echo "Options:"
      echo "  --version, -v VERSION  Install a specific version (default: latest release)"
      echo "  --prefix, -p PREFIX    Install prefix (default: /usr/local)"
      echo "  --help, -h             Show this help"
      echo ""
      echo "Environment variables:"
      echo "  ASM_AGENT_API_KEY      API key for the agent (written to ~/.asm-agent.env)"
      exit 0
      ;;
    *)
      fail "Unknown option: $1. Use --help for usage."
      ;;
  esac
done

# --- Banner ---
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║       ASM-AGENT Installer            ║${NC}"
echo -e "${BOLD}  ║   x86-64 NASM Autonomous Agent       ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════╝${NC}"
echo ""

# --- Preflight checks ---
info "Checking dependencies..."

command -v curl >/dev/null 2>&1 || fail "curl is required. Install: sudo apt install curl"
ok "curl found: $(command -v curl)"

ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  fail "Unsupported architecture: $ARCH. asm-agent only supports x86_64."
fi
ok "Architecture: x86_64"

# Check for write permission on install prefix
NEED_SUDO=0
if [ ! -w "$INSTALL_PREFIX" ] 2>/dev/null && [ "$(id -u)" -ne 0 ]; then
  warn "No write access to $INSTALL_PREFIX — will use sudo."
  NEED_SUDO=1
fi

# --- Resolve version ---
if [ -z "$VERSION" ]; then
  info "Fetching latest release version..."
  VERSION_JSON=$(curl -sSf "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>/dev/null) || {
    VERSION_JSON=$(curl -sSf "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/releases" 2>/dev/null) || {
      fail "Could not fetch release info. Check internet or repo name."
    }
  }
  VERSION=$(echo "$VERSION_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)
  [ -z "$VERSION" ] && fail "Could not determine latest version."
fi
ok "Version: ${BOLD}${VERSION}${NC}"

# --- Construct download URL (standalone binary) ---
BINARY_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/${BINARY_NAME}"
CHECKSUM_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/checksums.sha256"

# --- Create temp directory ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Download binary directly ---
info "Downloading ${BINARY_NAME}..."
HTTP_CODE=$(curl -w '%{http_code}' -sSL -o "${TMPDIR}/${BINARY_NAME}" "$BINARY_URL")
if [ "$HTTP_CODE" -ne 200 ]; then
  fail "Download failed (HTTP ${HTTP_CODE}). Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
fi
DOWNLOADED_SIZE=$(stat -c %s "${TMPDIR}/${BINARY_NAME}" 2>/dev/null || echo "?")
ok "Downloaded ${DOWNLOADED_SIZE} bytes"

# --- Verify checksum (optional) ---
if command -v sha256sum >/dev/null 2>&1; then
  info "Verifying checksum..."
  if EXPECTED=$(curl -sSf "$CHECKSUM_URL" 2>/dev/null | grep -oP "^\K[0-9a-f]+" | head -1); then
    ACTUAL=$(sha256sum "${TMPDIR}/${BINARY_NAME}" | awk '{print $1}')
    if [ "$ACTUAL" = "$EXPECTED" ]; then
      ok "Checksum verified"
    else
      warn "Checksum mismatch (expected ${EXPECTED:0:16}... got ${ACTUAL:0:16}...)"
    fi
  else
    warn "Could not fetch checksums. Skipping."
  fi
fi

# --- Verify ELF binary (no 'file' dependency) ---
info "Verifying binary..."
MAGIC=$(od -A n -t x1 -N 5 "${TMPDIR}/${BINARY_NAME}" 2>/dev/null | tr -d ' ')
if [ "$MAGIC" = "7f454c4602" ]; then
  ok "Verified: ELF 64-bit executable"
else
  fail "Not a valid ELF 64-bit binary (magic: ${MAGIC:-empty})"
fi

# --- Install ---
INSTALL_DIR="${INSTALL_PREFIX}/bin"
info "Installing to ${INSTALL_DIR}/${BINARY_NAME}..."

if [ "$NEED_SUDO" -eq 1 ]; then
  sudo mkdir -p "$INSTALL_DIR"
  sudo cp "${TMPDIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
  sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
else
  mkdir -p "$INSTALL_DIR"
  cp "${TMPDIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
  chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
fi
ok "Installed to ${BOLD}${INSTALL_DIR}/${BINARY_NAME}${NC}"

# --- Setup environment file ---
ENV_FILE="$HOME/.asm-agent.env"
if [ -n "${ASM_AGENT_API_KEY:-}" ]; then
  info "Writing API key to ${ENV_FILE}"
  cat > "$ENV_FILE" << ENVEOF
# asm-agent environment
# Source this file or add to your shell profile:
#   source ~/.asm-agent.env
export ASM_AGENT_API_KEY="${ASM_AGENT_API_KEY}"
ENVEOF
  chmod 600 "$ENV_FILE"
  ok "API key saved to ${ENV_FILE} (chmod 600)"
else
  info "Creating env template at ${ENV_FILE}"
  cat > "$ENV_FILE" << ENVEOF
# asm-agent environment
# Set your API key here:
#   export ASM_AGENT_API_KEY="sk-your-key-here"
#
# Then source this file:
#   source ~/.asm-agent.env
ENVEOF
  ok "Env template created at ${ENV_FILE}"
fi

# --- Add source line to shell profile if not already there ---
add_source_to_profile() {
  local profile="$1"
  local marker="# asm-agent env"
  if [ -f "$profile" ] && ! grep -q "$marker" "$profile" 2>/dev/null; then
    echo "" >> "$profile"
    echo "$marker" >> "$profile"
    echo "[ -f ~/.asm-agent.env ] && . ~/.asm-agent.env" >> "$profile"
    ok "Added auto-source to ${profile}"
  fi
}

add_source_to_profile "$HOME/.bashrc"
if [ -f "$HOME/.zshrc" ]; then
  add_source_to_profile "$HOME/.zshrc"
fi

# --- Verify installation ---
echo ""
info "Verifying installation..."
if command -v asm-agent >/dev/null 2>&1; then
  INSTALLED_PATH=$(command -v asm-agent)
  INSTALLED_SIZE=$(stat -c %s "$INSTALLED_PATH" 2>/dev/null || echo "?")
  ok "asm-agent is available at ${INSTALLED_PATH} (${INSTALLED_SIZE} bytes)"
elif [ -x "${INSTALL_DIR}/${BINARY_NAME}" ]; then
  ok "asm-agent installed at ${INSTALL_DIR}/${BINARY_NAME}"
  warn "Not in your PATH. Add ${INSTALL_DIR} to PATH or re-login."
else
  fail "Installation verification failed."
fi

# --- Done ---
echo ""
echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}  ║     Installation Complete!            ║${NC}"
echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo ""
echo "    1. Set your API key:"
echo -e "       ${CYAN}export ASM_AGENT_API_KEY=\"your-api-key\"${NC}"
echo ""
echo "    2. Run the agent:"
echo -e "       ${CYAN}asm-agent \"Create a hello world Python script at /tmp/hello.py\"${NC}"
echo ""
echo -e "  ${BOLD}Tips:${NC}"
echo "    - The env file is at ${ENV_FILE}"
echo "    - Source it: source ~/.asm-agent.env"
echo "    - Binary has ${BOLD}zero dependencies${NC} (static ELF64, no libc)"
echo ""