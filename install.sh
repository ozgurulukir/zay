#!/usr/bin/env bash
# Zay Agent Installer (Linux & macOS)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ozgurulukir/zay/main/install.sh | bash

set -euo pipefail

REPO="ozgurulukir/zay"
INSTALL_DIR="${ZAY_INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="zay"

# Colors
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${BOLD}${BLUE}==> Installing Zay Agent...${RESET}"

# Detect OS & Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64)
        ARTIFACT="zay-linux-x86_64"
        ;;
      *)
        echo -e "${RED}Error: Unsupported architecture: $ARCH on Linux. Currently x86_64 is supported.${RESET}" >&2
        exit 1
        ;;
    esac
    ;;
  Darwin)
    case "$ARCH" in
      arm64)
        ARTIFACT="zay-macos-aarch64"
        ;;
      *)
        echo -e "${RED}Error: Unsupported architecture: $ARCH on macOS. Currently arm64 (Apple Silicon) is supported.${RESET}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo -e "${RED}Error: Unsupported operating system: $OS. Linux x86_64, macOS arm64 and Windows x86_64 are currently supported.${RESET}" >&2
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

# Get release URL (allow ZAY_VERSION override e.g. ZAY_VERSION=v0.3.0)
if [ -n "${ZAY_VERSION:-}" ]; then
  BASE_URL="https://github.com/${REPO}/releases/download/${ZAY_VERSION}"
  echo -e "Targeting version: ${BOLD}${ZAY_VERSION}${RESET}"
else
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
  echo -e "Targeting version: ${BOLD}latest${RESET}"
fi

DOWNLOAD_URL="${BASE_URL}/${ARTIFACT}"
CHECKSUM_URL="${BASE_URL}/${ARTIFACT}.sha256"

echo -e "${BLUE}==>${RESET} Downloading ${BOLD}${ARTIFACT}${RESET}..."
curl -fL --progress-bar "$DOWNLOAD_URL" -o "$TEMP_DIR/$ARTIFACT"

echo -e "${BLUE}==>${RESET} Verifying SHA256 checksum..."

# Resolve the checksum tool up front. The old chain silently skipped the
# check when neither tool existed and still printed "Checksum verified." (#451).
# ZAY_SKIP_CHECKSUM=1 is the explicit opt-out for the two "verification is
# impossible" cases (no tool, checksum file unavailable); it never bypasses a
# FAILED verification — a checksum mismatch always aborts.
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  if [ "${ZAY_SKIP_CHECKSUM:-0}" = "1" ]; then
    echo -e "${YELLOW}Warning: ZAY_SKIP_CHECKSUM=1 set and no sha256 tool available, installing an unverified binary.${RESET}"
  else
    echo -e "${RED}Error: no sha256 tool available (need sha256sum or shasum).${RESET}" >&2
    echo -e "${YELLOW}Set ZAY_SKIP_CHECKSUM=1 to install an unverified binary at your own risk.${RESET}" >&2
    exit 1
  fi
elif curl -fLs "$CHECKSUM_URL" -o "$TEMP_DIR/$ARTIFACT.sha256"; then
  (
    cd "$TEMP_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
      if sha256sum --status -c "${ARTIFACT}.sha256"; then
        echo -e "${GREEN}✓ Checksum verified.${RESET}"
      else
        echo -e "${RED}Checksum verification failed!${RESET}" >&2
        exit 1
      fi
    elif command -v shasum >/dev/null 2>&1; then
      if shasum -a 256 --status -c "${ARTIFACT}.sha256"; then
        echo -e "${GREEN}✓ Checksum verified.${RESET}"
      else
        echo -e "${RED}Checksum verification failed!${RESET}" >&2
        exit 1
      fi
    fi
  )
elif [ "${ZAY_SKIP_CHECKSUM:-0}" = "1" ]; then
  echo -e "${YELLOW}Warning: ZAY_SKIP_CHECKSUM=1 set and checksum file not available, installing an unverified binary.${RESET}"
else
  echo -e "${RED}Error: Checksum file not available; refusing to install an unverified binary.${RESET}" >&2
  echo -e "${YELLOW}Set ZAY_SKIP_CHECKSUM=1 to install an unverified binary at your own risk.${RESET}" >&2
  exit 1
fi

# Move binary to target path and make executable
mv "$TEMP_DIR/$ARTIFACT" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"

# Best-effort: install the offline registry seed (the vendored models.dev
# snapshot) at <install-root>/share/zay/api.json — the runtime looks for it
# one level above the exe directory and seeds its model cache from it when
# the network is unavailable. Unlike the binary checksum above, this fetch is
# graceful degradation: any failure warns and continues, and the app fetches
# https://models.dev/api.json at runtime. An unverified seed is never installed.
API_PREFIX_DIR="$(dirname "$INSTALL_DIR")"
API_TEMP="$TEMP_DIR/api.json"
if curl -fLs --connect-timeout 30 --max-time 300 "$BASE_URL/api.json" -o "$API_TEMP"; then
  if curl -fLs --connect-timeout 30 --max-time 300 "$BASE_URL/api.json.sha256" -o "$TEMP_DIR/api.json.sha256"; then
    if (cd "$TEMP_DIR" && sha256sum -c api.json.sha256 --status >/dev/null 2>&1) || (cd "$TEMP_DIR" && shasum -a 256 -c api.json.sha256 --status >/dev/null 2>&1); then
      mkdir -p "$API_PREFIX_DIR/share/zay"
      mv "$API_TEMP" "$API_PREFIX_DIR/share/zay/api.json"
      echo -e "${GREEN}✓ Offline registry seed installed to ${API_PREFIX_DIR}/share/zay/api.json${RESET}"
    else
      echo -e "${YELLOW}Warning: api.json checksum mismatch; skipping the offline registry seed.${RESET}"
    fi
  else
    echo -e "${YELLOW}Warning: api.json checksum file not available; skipping the offline registry seed.${RESET}"
  fi
else
  echo -e "${YELLOW}Warning: api.json (offline registry seed) not available; skipping.${RESET}"
fi

echo -e "${GREEN}${BOLD}==> Zay Agent installed successfully to ${INSTALL_DIR}/${BIN_NAME}!${RESET}"

# macOS Gatekeeper flags unsigned binaries downloaded from the internet.
if [ "$OS" = "Darwin" ]; then
  echo ""
  echo -e "${YELLOW}Note: if macOS reports the binary cannot be verified, run:${RESET}"
  echo -e "  ${BOLD}xattr -d com.apple.quarantine \"${INSTALL_DIR}/${BIN_NAME}\"${RESET}"
fi

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
echo -e "Run ${BOLD}zay${RESET} to get started."
