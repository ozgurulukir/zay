#!/usr/bin/env bash
# Nova Agent Installer (Linux & macOS)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.sh | bash

set -euo pipefail

REPO="ozgurulukir/nova-agent"
INSTALL_DIR="${NOVA_INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="nova"

# Colors
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${BOLD}${BLUE}==> Installing Nova Agent...${RESET}"

# Detect OS & Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64)
        ARTIFACT="nova-linux-x86_64"
        ;;
      *)
        echo -e "${RED}Error: Unsupported architecture: $ARCH on Linux. Currently x86_64 is supported.${RESET}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo -e "${RED}Error: Unsupported operating system: $OS. Linux x86_64 and Windows x86_64 are currently supported.${RESET}" >&2
    exit 1
    ;;
esac

# Create target installation directory
mkdir -p "$INSTALL_DIR"

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Get release URL (allow NOVA_VERSION override e.g. NOVA_VERSION=v0.3.0)
if [ -n "${NOVA_VERSION:-}" ]; then
  BASE_URL="https://github.com/${REPO}/releases/download/${NOVA_VERSION}"
  echo -e "Targeting version: ${BOLD}${NOVA_VERSION}${RESET}"
else
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
  echo -e "Targeting version: ${BOLD}latest${RESET}"
fi

DOWNLOAD_URL="${BASE_URL}/${ARTIFACT}"
CHECKSUM_URL="${BASE_URL}/${ARTIFACT}.sha256"

echo -e "${BLUE}==>${RESET} Downloading ${BOLD}${ARTIFACT}${RESET}..."
curl -fL --progress-bar "$DOWNLOAD_URL" -o "$TEMP_DIR/$ARTIFACT"

echo -e "${BLUE}==>${RESET} Verifying SHA256 checksum..."
if curl -fLs "$CHECKSUM_URL" -o "$TEMP_DIR/$ARTIFACT.sha256"; then
  (
    cd "$TEMP_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c "${ARTIFACT}.sha256" --status || { echo -e "${RED}Checksum verification failed!${RESET}" >&2; exit 1; }
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 -c "${ARTIFACT}.sha256" --status || { echo -e "${RED}Checksum verification failed!${RESET}" >&2; exit 1; }
    fi
  )
  echo -e "${GREEN}✓ Checksum verified.${RESET}"
else
  echo -e "${YELLOW}Warning: Checksum file not available, skipping verification.${RESET}"
fi

# Move binary to target path and make executable
mv "$TEMP_DIR/$ARTIFACT" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"

echo -e "${GREEN}${BOLD}==> Nova Agent installed successfully to ${INSTALL_DIR}/${BIN_NAME}!${RESET}"

# Check PATH
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    echo ""
    echo -e "${YELLOW}Note: '${INSTALL_DIR}' is not in your PATH.${RESET}"
    echo -e "Add it to your shell configuration (e.g. ~/.bashrc or ~/.zshrc):"
    echo -e "  ${BOLD}export PATH=\"\$PATH:${INSTALL_DIR}\"${RESET}"
    ;;
esac

echo ""
echo -e "Run ${BOLD}nova --help${RESET} to get started."
