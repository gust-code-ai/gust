#!/usr/bin/env bash
set -euo pipefail

# --------------------------
# Config (can be overridden by flags)
# --------------------------
REPO=""
BINARY_NAME="mytool"
INSTALL_DIR="${HOME}/.local/bin"
VERSION="" # e.g. v1.2.3; if empty, uses latest

# --------------------------
# Helpers
# --------------------------
err() { printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }
info() { printf "\033[32m[INFO]\033[0m %s\n" "$*\n"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*\n"; }

need() { command -v "$1" >/dev/null 2>&1 || err "Missing dependency: $1"; }

usage() {
  cat <<EOF
Usage: install.sh --repo <owner/repo> --name <binary-name> [--version vX.Y.Z] [--to DIR]

Options:
  --repo       GitHub repo in owner/repo form (required)
  --name       Installed binary name (default: ${BINARY_NAME})
  --version    Release tag to install (e.g. v1.2.3). If omitted, installs latest.
  --to         Install directory (default: ${INSTALL_DIR})
  -h|--help    Show help

Notes:
  • Expects release assets named like: <name>-<os>-<arch>[.tar.gz|.zip] or a raw executable.
  • Supported os: linux, darwin. Supported arch: amd64/x86_64, arm64/aarch64.
  • Verifies SHA256 when a SHA256SUMS file is present in the release.
EOF
}

# --------------------------
# Parse args
# --------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --name) BINARY_NAME="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --to) INSTALL_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown flag: $1 (see --help)";;
  esac
done

[[ -z "${REPO}" ]] && { usage; err "--repo is required (e.g. --repo acme/mytool)"; }

# --------------------------
# Detect platform
# --------------------------
UNAME_S="$(uname -s | tr '[:upper:]' '[:lower:]')"
UNAME_M="$(uname -m | tr '[:upper:]' '[:lower:]')"

case "$UNAME_S" in
  linux*)   OS="linux" ;;
  darwin*)  OS="darwin" ;;
  *)        err "Unsupported OS: $UNAME_S" ;;
esac

case "$UNAME_M" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) err "Unsupported arch: $UNAME_M" ;;
esac

info "Detected platform: ${OS}-${ARCH}"

# --------------------------
# Requirements
# --------------------------
need curl
need tar
# unzip is optional; only needed if we pick a .zip asset
if ! command -v unzip >/dev/null 2>&1; then
  warn "unzip not found; .zip assets won't be supported"
fi

# --------------------------
# Resolve release JSON
# --------------------------
API_URL="https://api.github.com/repos/${REPO}/releases"
if [[ -n "${VERSION}" ]]; then
  RELEASE_URL="${API_URL}/tags/${VERSION}"
else
  RELEASE_URL="${API_URL}/latest"
fi

# Note: GITHUB_TOKEN respected if set (for higher rate limits)
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
fi

info "Fetching release metadata from ${RELEASE_URL}"
RELEASE_JSON="$(curl -fsSL "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github+json" "$RELEASE_URL")" \
  || err "Failed to fetch release metadata"

# Extract tag name (for messaging)
TAG_NAME="$(printf "%s" "$RELEASE_JSON" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[[ -n "${TAG_NAME}" ]] || TAG_NAME="${VERSION:-unknown}"

# --------------------------
# Find matching asset
# --------------------------
# We'll search for assets in order:
#   1) <name>-<os>-<arch>.tar.gz
#   2) <name>_<os>_<arch>.tar.gz
#   3) <name>-<os>-<arch>.zip
#   4) <name>_<os>_<arch>.zip
#   5) raw executable named <name>-<os>-<arch> or <name>_<os>_<arch> or <name>
ASSET_URL=""
choose_asset() {
  local patterns=(
    "${BINARY_NAME}-${OS}-${ARCH}\\.tar\\.gz"
    "${BINARY_NAME}_${OS}_${ARCH}\\.tar\\.gz"
    "${BINARY_NAME}-${OS}-${ARCH}\\.zip"
    "${BINARY_NAME}_${OS}_${ARCH}\\.zip"
    "${BINARY_NAME}-${OS}-${ARCH}(\\.exe)?\""
    "${BINARY_NAME}_${OS}_${ARCH}(\\.exe)?\""
    "${BINARY_NAME}(\\.exe)?\""
  )
  local p
  for p in "${patterns[@]}"; do
    ASSET_URL="$(printf "%s" "$RELEASE_JSON" \
      | sed -n "s/.*\"browser_download_url\":[[:space:]]*\"\([^\"]*${p}\).*/\1/p" \
      | head -n1)"
    if [[ -n "$ASSET_URL" ]]; then
      echo "$ASSET_URL"
      return 0
    fi
  done
  return 1
}

ASSET_URL="$(choose_asset || true)"
[[ -n "${ASSET_URL}" ]] || err "No asset matched ${OS}-${ARCH}. Ensure your release includes ${BINARY_NAME}-{${OS}|${ARCH}} assets."

info "Selected asset: ${ASSET_URL}"

# Optional: find SHA256SUMS url if present
SUMS_URL="$(printf "%s" "$RELEASE_JSON" \
  | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*SHA256SUMS[^"]*\)".*/\1/p' \
  | head -n1 || true)"

# --------------------------
# Download to temp and unpack
# --------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ASSET_FILE="${TMPDIR}/asset"
info "Downloading asset..."
curl -fsSL "${AUTH_HEADER[@]}" -o "$ASSET_FILE" "$ASSET_URL"

# Verify SHA256 if sums file exists
if [[ -n "$SUMS_URL" ]]; then
  info "Verifying SHA256 checksum..."
  SUMS_FILE="${TMPDIR}/SHA256SUMS"
  curl -fsSL "${AUTH_HEADER[@]}" -o "$SUMS_FILE" "$SUMS_URL"
  # Try to extract just our asset's filename from the URL for matching
  ASSET_BASENAME="$(basename "$ASSET_URL")"
  if grep -q "$ASSET_BASENAME" "$SUMS_FILE"; then
    # GNU vs BSD sha256sum compatibility: prefer shasum if sha256sum not present
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$TMPDIR" && grep " $ASSET_BASENAME" SHA256SUMS | sha256sum -c -) \
        || err "Checksum verification failed"
    else
      # macOS shasum
      EXPECTED="$(grep " $ASSET_BASENAME" "$SUMS_FILE" | awk '{print $1}')"
      ACTUAL="$(shasum -a 256 "$ASSET_FILE" | awk '{print $1}')"
      [[ "$EXPECTED" = "$ACTUAL" ]] || err "Checksum verification failed"
    fi
    info "Checksum OK"
  else
    warn "No matching entry for ${ASSET_BASENAME} in SHA256SUMS; skipping verification."
  fi
else
  warn "No SHA256SUMS found in release; skipping checksum verification."
fi

WORKDIR="${TMPDIR}/work"
mkdir -p "$WORKDIR"

# Determine type and extract
FILETYPE="$(file -b "$ASSET_FILE" || true)"
echo $ASSET_FILE
BIN_PATH=""
case "$ASSET_FILE" in
  *.tar.gz|*.tgz)
    info "Extracting tar.gz..."
    tar -xzf "$ASSET_FILE" -C "$WORKDIR"
    ;;
  *.zip)
    need unzip
    info "Extracting zip..."
    unzip -q "$ASSET_FILE" -d "$WORKDIR"
    ;;
  *)
    # Might be a raw binary
    cp "$ASSET_FILE" "$WORKDIR/${BINARY_NAME}"
    ;;
esac

# Find the binary inside WORKDIR
if [[ -z "${BIN_PATH}" ]]; then
  # Prefer a file named exactly BINARY_NAME or BINARY_NAME.exe
  if [[ -f "$WORKDIR/${BINARY_NAME}" ]]; then
    BIN_PATH="$WORKDIR/${BINARY_NAME}"
  elif [[ -f "$WORKDIR/${BINARY_NAME}.exe" ]]; then
    BIN_PATH="$WORKDIR/${BINARY_NAME}.exe"
  else
    # Otherwise pick the first executable file
    BIN_PATH="$(find "$WORKDIR" -type f -perm -u+x -maxdepth 2 | head -n1 || true)"
  fi
fi

[[ -n "$BIN_PATH" && -f "$BIN_PATH" ]] || err "Could not locate executable in asset"
chmod +x "$BIN_PATH"

# --------------------------
# Install
# --------------------------
mkdir -p "$INSTALL_DIR"
TARGET="${INSTALL_DIR}/${BINARY_NAME}"
mv "$BIN_PATH" "$TARGET"

info "Installed ${BINARY_NAME} (${TAG_NAME}) to ${TARGET}"

# macOS gatekeeper note (optional)
if [[ "$OS" = "darwin" ]]; then
  xattr -d com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
fi

# Path hint
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) : ;; # already in PATH
  *)
    warn "${INSTALL_DIR} is not in your PATH."
    echo "Add this line to your shell profile (e.g. ~/.bashrc or ~/.zshrc):"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    ;;
esac

# Smoke test
if "${TARGET}" --version >/dev/null 2>&1; then
  info "Launch check: '${BINARY_NAME} --version' succeeded."
else
  warn "Couldn't run '${BINARY_NAME} --version'. If this is expected, ignore."
fi

info "Done."
