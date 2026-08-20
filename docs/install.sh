#!/bin/sh
set -e

# Installs a pinned GitHub release. Never queries the latest-release API.
# Override the pin with TREEHOUSE_VERSION=vX.Y.Z (still checksum-verified).
REPO="kunchenguid/treehouse"
PINNED_VERSION="v2.1.1"
PINNED_RELEASE_BASE="https://github.com/kunchenguid/treehouse/releases/download/v2.1.1"

# Prefer ~/.local/bin if it exists and is in PATH (no sudo needed).
# Fall back to /usr/local/bin otherwise.
if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
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

if [ -n "${TREEHOUSE_VERSION:-}" ]; then
  VERSION="$TREEHOUSE_VERSION"
  # Reject unpinned or path-like values so the download URL cannot drift
  # to a floating tag or escape the releases/download/<tag>/ prefix.
  case "$VERSION" in
    *[!A-Za-z0-9._-]*|"")
      echo "Invalid TREEHOUSE_VERSION: $VERSION" >&2
      exit 1
      ;;
    v[0-9]*) ;;
    *)
      echo "Invalid TREEHOUSE_VERSION: $VERSION (expected vX.Y.Z)" >&2
      exit 1
      ;;
  esac
  RELEASE_BASE="https://github.com/${REPO}/releases/download/${VERSION}"
else
  VERSION="$PINNED_VERSION"
  RELEASE_BASE="$PINNED_RELEASE_BASE"
fi

VERSION_NUM="${VERSION#v}"
FILENAME="treehouse-v${VERSION_NUM}-${OS}-${ARCH}.tar.gz"
URL="${RELEASE_BASE}/${FILENAME}"
CHECKSUMS_URL="${RELEASE_BASE}/checksums.txt"

# --- begin verify_archive_checksum ---
# Fail closed: missing checksums, missing entry, bad hash, or tool absence
# all abort. Never warn-and-continue.
verify_archive_checksum() {
  archive="$1"
  checksums="$2"
  filename="$(basename "$archive")"

  if [ ! -f "$checksums" ] || [ ! -s "$checksums" ]; then
    echo "error: checksums.txt is missing or empty; refusing to install" >&2
    return 1
  fi
  if [ ! -f "$archive" ]; then
    echo "error: archive missing: $archive" >&2
    return 1
  fi

  expected="$(awk -v f="$filename" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == f && $1 ~ /^[0-9a-fA-F]{64}$/) {
        print $1
        n++
      }
    }
    END { if (n != 1) exit 1 }
  ' "$checksums")" || {
    echo "error: no unique SHA-256 for ${filename} in checksums.txt; refusing to install" >&2
    return 1
  }

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  else
    echo "error: need sha256sum or shasum to verify download; refusing to install" >&2
    return 1
  fi

  expected_lc="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  actual_lc="$(printf '%s' "$actual" | tr 'A-F' 'a-f')"
  if [ "$actual_lc" != "$expected_lc" ]; then
    echo "error: checksum mismatch for ${filename}; refusing to install" >&2
    echo "  expected: ${expected_lc}" >&2
    echo "  got:      ${actual_lc}" >&2
    return 1
  fi
}
# --- end verify_archive_checksum ---

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading treehouse ${VERSION} for ${OS}/${ARCH}..."
curl -fsSL "$URL" -o "${TMPDIR}/${FILENAME}"

echo "Verifying SHA-256 against ${CHECKSUMS_URL}..."
curl -fsSL "$CHECKSUMS_URL" -o "${TMPDIR}/checksums.txt"
verify_archive_checksum "${TMPDIR}/${FILENAME}" "${TMPDIR}/checksums.txt"

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
