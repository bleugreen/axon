#!/bin/sh

# Axon installer for macOS and Linux.
set -eu
# pipefail is not specified by POSIX (notably, dash does not implement it). Enable it when the
# system shell provides it; this script does not otherwise depend on pipelines for correctness.
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

REPOSITORY="bleugreen/axon"
API_URL="https://api.github.com/repos/$REPOSITORY/releases/latest"
RELEASES_URL="https://github.com/$REPOSITORY/releases/download"

fail() {
  printf 'Axon install failed: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command '$1' was not found; install it and run this installer again"
}

need curl

OS_NAME="$(uname -s 2>/dev/null || printf unknown)"
ARCH_NAME="$(uname -m 2>/dev/null || printf unknown)"
case "$OS_NAME/$ARCH_NAME" in
  Darwin/arm64 | Darwin/aarch64)
    PLATFORM="macos/aarch64"
    OS="macos"
    ;;
  Linux/x86_64 | Linux/amd64)
    PLATFORM="linux/x86_64"
    OS="linux"
    ;;
  *)
    fail "unsupported platform $OS_NAME/$ARCH_NAME; release binaries exist only for macos/aarch64, linux/x86_64, and windows/x86_64"
    ;;
esac

if [ "$OS" = macos ] && command -v brew >/dev/null 2>&1 && brew list --cask bleugreen/tap/axon >/dev/null 2>&1; then
  printf '%s\n' 'Axon is managed by Homebrew on this machine; no second copy will be installed.'
  printf '%s\n' 'Upgrade it with: brew upgrade --cask bleugreen/tap/axon'
  exit 0
fi

if [ -n "${AXON_VERSION:-}" ]; then
  VERSION="${AXON_VERSION#v}"
else
  RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$API_URL")" ||
    fail "could not resolve the latest release from $API_URL; check your network or set AXON_VERSION to a published version"
  VERSION="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$VERSION" ] || fail "GitHub's latest-release response did not contain a version; set AXON_VERSION to a published version"
fi

case "$VERSION" in
  '' | *[!0-9A-Za-z._+-]*) fail "invalid version '$VERSION'; use a release version such as 0.3.1" ;;
esac

case "$OS" in
  macos)
    ARCHIVE="Axon-$VERSION-macos-aarch64.zip"
    ARCHIVE_KIND="zip"
    CONTENT_DIR="Axon-$VERSION"
    RELATIVE_CLI="Axon.app/Contents/Resources/bin/axon"
    ;;
  linux)
    ARCHIVE="axon-linux-$VERSION-linux-x86_64.tar.gz"
    ARCHIVE_KIND="tar"
    CONTENT_DIR="axon-linux-$VERSION-linux-x86_64"
    RELATIVE_CLI="axon-linux"
    ;;
esac

INSTALL_DIR="$HOME/.local/lib/axon/$VERSION"
BIN_DIR="$HOME/.local/bin"
LINK_PATH="$BIN_DIR/axon"
MARKER="$INSTALL_DIR/.axon-install-complete"
CLI="$INSTALL_DIR/$RELATIVE_CLI"

if [ -f "$MARKER" ] && [ -x "$CLI" ]; then
  printf 'Axon %s is already installed at %s (%s).\n' "$VERSION" "$INSTALL_DIR" "$PLATFORM"
  printf 'CLI: %s\n' "$LINK_PATH"
  exit 0
fi

case "$ARCHIVE_KIND" in
  zip) need unzip ;;
  tar) need tar ;;
esac
if command -v shasum >/dev/null 2>&1; then
  SHA_COMMAND=shasum
elif command -v sha256sum >/dev/null 2>&1; then
  SHA_COMMAND=sha256sum
else
  fail "neither shasum nor sha256sum was found; install one and run this installer again"
fi

TMP_DIR="$(mktemp -d 2>/dev/null)" || fail "could not create a temporary directory"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

ARCHIVE_PATH="$TMP_DIR/$ARCHIVE"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
BASE_URL="$RELEASES_URL/v$VERSION"
printf 'Downloading Axon %s for %s...\n' "$VERSION" "$PLATFORM"
curl -fL --retry 3 --output "$ARCHIVE_PATH" "$BASE_URL/$ARCHIVE" ||
  fail "could not download $ARCHIVE; confirm that version $VERSION has a $PLATFORM release at $BASE_URL"
curl -fL --retry 3 --output "$CHECKSUM_PATH" "$BASE_URL/$ARCHIVE.sha256" ||
  fail "could not download $ARCHIVE.sha256; the archive was not installed"

EXPECTED_SHA="$(awk 'NR == 1 { print $1 }' "$CHECKSUM_PATH")"
case "$EXPECTED_SHA" in
  '' | *[!0-9A-Fa-f]*) fail "the published checksum for $ARCHIVE is malformed; the archive was not installed" ;;
esac
if [ "$SHA_COMMAND" = shasum ]; then
  ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')"
else
  ACTUAL_SHA="$(sha256sum "$ARCHIVE_PATH" | awk '{ print $1 }')"
fi
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail "checksum verification failed for $ARCHIVE; expected $EXPECTED_SHA but downloaded $ACTUAL_SHA"
printf 'Verified SHA-256: %s\n' "$ACTUAL_SHA"

EXTRACT_DIR="$TMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
if [ "$ARCHIVE_KIND" = zip ]; then
  unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR" || fail "could not unpack $ARCHIVE with unzip"
else
  tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" || fail "could not unpack $ARCHIVE with tar"
fi
SOURCE_DIR="$EXTRACT_DIR/$CONTENT_DIR"
[ -d "$SOURCE_DIR" ] || fail "$ARCHIVE did not contain the expected directory $CONTENT_DIR"
[ -x "$SOURCE_DIR/$RELATIVE_CLI" ] || fail "$ARCHIVE did not contain the expected executable $RELATIVE_CLI"

mkdir -p "$INSTALL_DIR" || fail "could not create permanent install directory $INSTALL_DIR"
cp -R "$SOURCE_DIR"/. "$INSTALL_DIR"/ || fail "could not copy Axon into permanent install directory $INSTALL_DIR"
[ -x "$CLI" ] || fail "the installed CLI is not executable at $CLI"

printf 'Registering the daemon from permanent path %s...\n' "$CLI"
"$CLI" daemon install

mkdir -p "$BIN_DIR" || fail "could not create PATH directory $BIN_DIR"
ln -sfn "$CLI" "$LINK_PATH" || fail "could not link $LINK_PATH to $CLI"
printf '%s\n' "$VERSION" > "$MARKER" || fail "installation succeeded but its completion marker could not be written at $MARKER"

printf '\nAxon %s installed successfully.\n' "$VERSION"
printf 'CLI: %s -> %s\n' "$LINK_PATH" "$CLI"
case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'Add %s to PATH, then open a new shell.\n' "$BIN_DIR" ;;
esac
printf '\nRegister Axon with an MCP client:\n'
printf '  claude mcp add axon -- axon mcp\n'
printf '  codex mcp add axon -- axon mcp\n'
if [ "$OS" = macos ]; then
  printf '\nApprove Axon.app in System Settings -> Privacy & Security -> Accessibility.\n'
fi