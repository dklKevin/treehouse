#!/bin/sh
set -e

# Pin a published release. Do not follow /releases/latest — that URL can
# move to an unverified asset. Fail closed unless checksums.txt matches.
REPO="kunchenguid/treehouse"
VERSION="v2.1.1"
RELEASE_BASE="${TREEHOUSE_RELEASE_BASE:-https://github.com/${REPO}/releases/download/${VERSION}}"

# Prefer ~/.local/bin if it exists and is in PATH (no sudo needed).
# Fall back to /usr/local/bin otherwise.
if [ -n "${TREEHOUSE_INSTALL_DIR:-}" ]; then
  INSTALL_DIR="$TREEHOUSE_INSTALL_DIR"
elif echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  INSTALL_DIR="$HOME/.local/bin"
else
  INSTALL_DIR="/usr/local/bin"
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

case "$OS" in
  darwin|linux) ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

VERSION_NUM="${VERSION#v}"
FILENAME="treehouse-v${VERSION_NUM}-${OS}-${ARCH}.tar.gz"
URL="${RELEASE_BASE}/${FILENAME}"
CHECKSUMS_URL="${RELEASE_BASE}/checksums.txt"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading treehouse ${VERSION} for ${OS}/${ARCH}..."
curl -fsSL "$URL" -o "${TMPDIR}/${FILENAME}" || {
  echo "Failed to download ${URL}" >&2
  exit 1
}

echo "Verifying against checksums.txt..."
curl -fsSL "$CHECKSUMS_URL" -o "${TMPDIR}/checksums.txt" || {
  echo "Failed to download checksums.txt from ${CHECKSUMS_URL}" >&2
  exit 1
}

EXPECTED="$(awk -v f="$FILENAME" '$2 == f { print $1; found=1; exit } END { if (!found) exit 1 }' "${TMPDIR}/checksums.txt")" || {
  echo "checksums.txt has no SHA256 entry for ${FILENAME}" >&2
  exit 1
}

case "$EXPECTED" in
  *[!0-9a-fA-F]*)
    echo "checksums.txt has an invalid SHA256 for ${FILENAME}" >&2
    exit 1
    ;;
esac
if [ "${#EXPECTED}" -ne 64 ]; then
  echo "checksums.txt has an invalid SHA256 for ${FILENAME}" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "${TMPDIR}/${FILENAME}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "${TMPDIR}/${FILENAME}" | awk '{print $1}')"
else
  echo "No sha256sum or shasum found; cannot verify checksums.txt" >&2
  exit 1
fi

ACTUAL_LC="$(printf '%s' "$ACTUAL" | tr '[:upper:]' '[:lower:]')"
EXPECTED_LC="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
if [ -z "$ACTUAL_LC" ] || [ "$ACTUAL_LC" != "$EXPECTED_LC" ]; then
  echo "Checksum mismatch for ${FILENAME}" >&2
  echo "  expected: ${EXPECTED}" >&2
  echo "  actual:   ${ACTUAL}" >&2
  exit 1
fi

tar xzf "${TMPDIR}/${FILENAME}" -C "$TMPDIR"

if [ -w "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR"
  mv "${TMPDIR}/treehouse" "${INSTALL_DIR}/treehouse"
else
  echo "Installing to ${INSTALL_DIR} (requires sudo)..."
  sudo mkdir -p "$INSTALL_DIR"
  sudo mv "${TMPDIR}/treehouse" "${INSTALL_DIR}/treehouse"
fi

echo "treehouse ${VERSION} installed to ${INSTALL_DIR}/treehouse"
