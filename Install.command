#!/bin/zsh
# Double-click in the Finder: the guided setup opens in your browser.
# It runs ./setup.sh for you and turns its questions into buttons. ./setup.sh is the same setup, in Terminal.

cd "$(dirname "$0")" || exit 1
REPO="$PWD"
LOGS="$HOME/Library/Logs/rayban-meta-mac"
mkdir -p "$LOGS"
BUILD_LOG="$LOGS/install-build.log"

print -P "\n%BRay-Ban Meta for Mac: guided setup%b"
echo "The setup happens in your browser. Keep this window open until it is finished."
echo

# Apple's command line tools (Swift, git): macOS offers them in a window of its own.
if ! xcode-select -p > /dev/null 2>&1; then
  echo "First, Apple's command line tools. A macOS window offers to install them: click Install,"
  echo "accept, and wait until it is done (a few minutes). This window carries on by itself."
  xcode-select --install > /dev/null 2>&1
  osascript -e 'display notification "Click Install in the macOS window, then wait." with title "Ray-Ban Meta setup"' > /dev/null 2>&1
  until xcode-select -p > /dev/null 2>&1 && swift --version > /dev/null 2>&1; do sleep 5; done
  echo "Command line tools installed."
  echo
fi

echo "Preparing the setup page (about a minute the first time)..."
if ! swift build -c release --product visor-web > "$BUILD_LOG" 2>&1; then
  echo
  echo "The preparation failed. Last lines:"
  tail -n 20 "$BUILD_LOG"
  echo
  echo "Full log: $BUILD_LOG"
  read -k1 "?Press any key to close this window."
  exit 1
fi

# Run a copy: the setup rebuilds the app at its end, and a running program must not be replaced under itself.
RUN_DIR="$HOME/Library/Caches/visor-mac/setup-ui"
mkdir -p "$RUN_DIR"
cp -f .build/release/visor-web "$RUN_DIR/visor-web"

echo "The setup page opens in your browser. If it does not: http://127.0.0.1:47393/"
echo
VISOR_WEB_DIR="$REPO/web" "$RUN_DIR/visor-web" --setup --repo "$REPO"

echo
echo "The setup page is closed. You can close this window."
