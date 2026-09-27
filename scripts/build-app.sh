#!/bin/bash
# Builds build/HandControl.app from the HandControlApp target (release), signs it, and with
# --install copies it to ~/Applications.
#
# Signing: the first "Apple Development" identity in the keychain, or $SIGN_IDENTITY.
# macOS ties Camera and Accessibility grants to the code signature: with a certificate they
# survive rebuilds; with ad-hoc signing (SIGN_IDENTITY=-) macOS asks again after each build.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/HandControl.app"

swift build -c release --package-path "$ROOT" --product HandControlApp
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/HandControlApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/HandControl"
cp "$ROOT/Support/App-Info.plist" "$APP/Contents/Info.plist"

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -x HandControl > /dev/null; then
        echo "Hand Control is running; quit it from the menu bar first" >&2
        exit 1
    fi
    DEST="$HOME/Applications/HandControl.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "installed $DEST"
fi
