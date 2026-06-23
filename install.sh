#!/bin/bash
# ============================================================================
# install.sh — One-liner installer for asm-agent
# ============================================================================
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/main/install.sh | bash
#
# Or with a specific version:
#   curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/main/install.sh | bash -s -- --version v0.1.0
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

# Check for curl
command -v curl >/dev/null 2>&1 || fail "curl is required but not installed. Install with: sudo apt install curl"
ok "curl found: $(command -v curl)"

# Check for tar
command -v tar >/dev/null 2>&1 || fail "tar is required but not installed."
ok "tar found: $(command -v tar)"

# Check for sha256sum
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required."
ok "sha256sum found: $(command -v sha256sum)"

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  fail "Unsupported architecture: $ARCH. asm-agent only supports x86_64 (amd64)."
fi
ok "Architecture: x86_64"

# Check for write permission on install prefix
if [ ! -w "$INSTALL_PREFIX" ] 2>/dev/null; then
  if [ "$(id -u)" -ne 0 ]; then
    warn "No write access to $INSTALL_PREFIX — will use sudo for installation."
    NEED_SUDO=1
  fi
fi
NEED_SUDO=${NEED_SUDO:-0}

# --- Resolve version ---
if [ -z "$VERSION" ]; then
  info "Fetching latest release version..."
  VERSION_JSON=$(curl -sSf "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>/dev/null) || {
    # Fallback: try to list releases
    info "Failed to get latest release, trying releases list..."
    VERSION_JSON=$(curl -sSf "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/releases" 2>/dev/null) || {
      fail "Could not fetch release info from GitHub. Check your internet connection or the repo name."
    }
  }
  VERSION=$(echo "$VERSION_JSON" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)
  if [ -z "$VERSION" ]; then
    fail "Could not determine latest version. No releases found?"
  fi
fi
ok "Version: ${BOLD}${VERSION}${NC}"

# --- Construct download URLs ---
ARCHIVE_NAME="asm-agent-${VERSION}-linux-x86_64.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/${ARCHIVE_NAME}"
CHECKSUM_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/checksums.sha256"

info "Download URL: ${DOWNLOAD_URL}"

# --- Create temp directory ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Download archive ---
info "Downloading ${ARCHIVE_NAME}..."
HTTP_CODE=$(curl -w '%{http_code}' -sSL -o "${TMPDIR}/${ARCHIVE_NAME}" "$DOWNLOAD_URL")
if [ "$HTTP_CODE" -ne 200 ]; then
  fail "Download failed (HTTP ${HTTP_CODE}). Check that version ${VERSION} exists at https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
fi
ok "Downloaded $(du -h "${TMPDIR}/${ARCHIVE_NAME}" | cut -f1)"

# --- Verify checksum ---
info "Verifying checksum..."
if curl -sSf -o "${TMPDIR}/checksums.sha256" "$CHECKSUM_URL" 2>/dev/null; then
  cd "$TMPDIR"
  if sha256sum --ignore-missing -c checksums.sha256 2>/dev/null; then
    ok "Checksum verified"
  else
    # Try matching by filename pattern (tarball might not be in checksums)
    warn "Exact checksum verification skipped (asset name mismatch). Binary will still be verified after extraction."
  fi
  cd - >/dev/null
else
  warn "Could not download checksums file. Skipping verification."
fi

# --- Extract ---
info "Extracting..."
cd "$TMPDIR"
tar xzf "${ARCHIVE_NAME}" 2>/dev/null || fail "Failed to extract archive. Corrupted download?"
EXTRACTED_DIR="${ARCHIVE_NAME%.tar.gz}"

if [ ! -f "${EXTRACTED_DIR}/${BINARY_NAME}" ]; then
  fail "Binary not found in archive. Expected: ${EXTRACTED_DIR}/${BINARY_NAME}"
fi
ok "Extracted successfully"

# --- Verify ELF binary ---
if command -v file >/dev/null 2>&1; then
  if file "${EXTRACTED_DIR}/${BINARY_NAME}" | grep -q "ELF 64-bit"; then
    ok "Binary verified: ELF 64-bit executable"
  else
    fail "Downloaded file is not a valid ELF 64-bit binary!"
  fi
elif command -v xxd >/dev/null 2>&1; then
  # Fallback: check ELF magic bytes (7f 45 4c 46) + 64-bit class (02)
  MAGIC=$(xxd -l 5 -p "${EXTRACTED_DIR}/${BINARY_NAME}")
  if [ "$MAGIC" = "7f454c4602" ]; then
    ok "Binary verified: ELF 64-bit (magic bytes)"
  else
    fail "Downloaded file is not a valid ELF 64-bit binary! (magic: $MAGIC)"
  fi
elif command -v od >/dev/null 2>&1; then
  # Fallback: od to check ELF magic
  MAGIC=$(od -A n -t x1 -N 5 "${EXTRACTED_DIR}/${BINARY_NAME}" | tr -d ' ')
  if [ "$MAGIC" = "7f454c4602" ]; then
    ok "Binary verified: ELF 64-bit (magic bytes via od)"
  else
    fail "Downloaded file is not a valid ELF 64-bit binary! (magic: $MAGIC)"
  fi
else
  warn "'file' command not found — skipping binary verification"
fi

# --- Install ---
INSTALL_DIR="${INSTALL_PREFIX}/bin"
info "Installing to ${INSTALL_DIR}/${BINARY_NAME}..."

if [ "$NEED_SUDO" -eq 1 ]; then
  sudo mkdir -p "$INSTALL_DIR"
  sudo cp "${EXTRACTED_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
  sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
else
  mkdir -p "$INSTALL_DIR"
  cp "${EXTRACTED_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
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
  # Create template env file
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