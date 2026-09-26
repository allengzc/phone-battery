#!/usr/bin/env bash
# Fetch the Android SDK pieces that android/build.sh needs, into android/sdk.
#
# Everything comes from dl.google.com (no Gradle, no Android Studio). Roughly
# 250 MB downloaded, ~500 MB on disk.
#
# Requires a JDK: build-tools 34.0.0 must NOT be driven by JDK 21 (see the note
# in android/build.sh), so a JDK 17 is preferred and used if present.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$HERE/android/sdk"

case "$(uname -s)" in
    Darwin) CMDLINE="commandlinetools-mac-11076708_latest.zip" ;;
    Linux)  CMDLINE="commandlinetools-linux-11076708_latest.zip" ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

if [ -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
    echo "command-line tools already present"
else
    echo "==> downloading $CMDLINE"
    mkdir -p "$SDK"
    tmp="$(mktemp -d)"
    curl -L --retry 2 -o "$tmp/cmdline-tools.zip" \
        "https://dl.google.com/android/repository/$CMDLINE"
    unzip -q "$tmp/cmdline-tools.zip" -d "$tmp/extract"
    mkdir -p "$SDK/cmdline-tools"
    rm -rf "$SDK/cmdline-tools/latest"
    mv "$tmp/extract/cmdline-tools" "$SDK/cmdline-tools/latest"
    rm -rf "$tmp"
fi

# Keep every byte sdkmanager writes inside the checkout.
export ANDROID_USER_HOME="$HERE/android/.android"
mkdir -p "$ANDROID_USER_HOME"

SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"

echo "==> accepting licences"
yes 2>/dev/null | "$SDKMANAGER" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true

echo "==> installing platform + build-tools"
"$SDKMANAGER" --sdk_root="$SDK" "platforms;android-34" "build-tools;34.0.0"

echo
echo "done. now run: android/build.sh"
