#!/usr/bin/env bash
# Build and sign the APK without Gradle or the Android Gradle Plugin.
#
# Gradle/AGP would need maven.google.com (unreachable on this network); the SDK
# command-line tools, platform and build-tools all come from dl.google.com,
# which works. So: aapt2 -> javac -> d8 -> zipalign -> apksigner.
#
# Usage: ./build.sh   (run from anywhere; paths are resolved from this file)
#
# The SDK is expected at ./sdk (see scripts/setup-toolchains.sh), or set
# ANDROID_SDK_ROOT.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer a usable ANDROID_SDK_ROOT, else the SDK fetched by
# scripts/setup-toolchains.sh next to this script.
SDK="${ANDROID_SDK_ROOT:-}"
if [ -z "$SDK" ] || [ ! -d "$SDK/platforms" ]; then
  SDK="$HERE/sdk"
fi
APP="$HERE/app"
BUILD="$HERE/build"
OUT="$HERE/PhoneBatteryBLE.apk"

BUILD_TOOLS="$SDK/build-tools/34.0.0"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"

# JDK 17, not 21: javac 21 emits something in the InnerClasses/EnclosingMethod
# attributes of anonymous inner classes that R8 8.2.2 (build-tools 34.0.0) cannot
# read — it dies with "NullPointerException: String.length() ... <parameter1>
# is null" on BatteryGattService$3.class. Same source, same class-file major
# version 52; JDK 17's javac → d8 succeeds.
#
# /usr/libexec/java_home is macOS-only, so on any other platform (CI runs this on
# Linux) the caller's JAVA_HOME / PATH is used as-is.
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
  for v in 17 11; do
    candidate="$(/usr/libexec/java_home -v "$v" 2>/dev/null || true)"
    if [ -n "$candidate" ] && [ -x "$candidate/bin/javac" ]; then
      JAVA_HOME="$candidate"
      break
    fi
  done
  JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || true)}"
fi
if [ -n "${JAVA_HOME:-}" ]; then
  export JAVA_HOME
  export PATH="$BUILD_TOOLS:$JAVA_HOME/bin:$PATH"
else
  export PATH="$BUILD_TOOLS:$PATH"
fi
echo "using JDK: ${JAVA_HOME:-<from PATH>: $(command -v javac || echo none)}"

for tool in aapt2 d8 zipalign apksigner keytool javac; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool (looked in $BUILD_TOOLS and $JAVA_HOME/bin)" >&2; exit 1; }
done
[ -f "$ANDROID_JAR" ] || { echo "missing $ANDROID_JAR" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$BUILD/gen" "$BUILD/classes" "$BUILD/dex"

echo "==> aapt2 compile (resources)"
aapt2 compile --dir "$APP/res" -o "$BUILD/res.zip"

echo "==> aapt2 link (manifest + resources)"
aapt2 link \
  -o "$BUILD/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$APP/AndroidManifest.xml" \
  -R "$BUILD/res.zip" \
  --java "$BUILD/gen" \
  --min-sdk-version 26 \
  --target-sdk-version 34 \
  --version-code 4 \
  --version-name 1.3 \
  --auto-add-overlay

echo "==> javac"
find "$APP/src" "$BUILD/gen" -name '*.java' > "$BUILD/sources.txt"
if ! javac -source 8 -target 8 -nowarn -classpath "$ANDROID_JAR" \
      -d "$BUILD/classes" @"$BUILD/sources.txt" > "$BUILD/javac.log" 2>&1; then
  echo "javac failed:" >&2
  cat "$BUILD/javac.log" >&2
  exit 1
fi
echo "    compiled $(wc -l < "$BUILD/sources.txt" | tr -d ' ') source files"

echo "==> d8 (dex)"
find "$BUILD/classes" -name '*.class' > "$BUILD/classes.txt"
d8 --lib "$ANDROID_JAR" --min-api 26 --output "$BUILD/dex" @"$BUILD/classes.txt"

echo "==> package + align"
cp "$BUILD/base.apk" "$BUILD/unsigned.apk"
(cd "$BUILD/dex" && zip -q -X "$BUILD/unsigned.apk" classes.dex)
zipalign -f 4 "$BUILD/unsigned.apk" "$BUILD/aligned.apk"

echo "==> sign"
KS="$HERE/debug.keystore"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias androiddebugkey \
    -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Phone Battery BLE, OU=dsh, O=dsh, L=-, S=-, C=-" >/dev/null 2>&1
fi
apksigner sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT" "$BUILD/aligned.apk"
apksigner verify --print-certs "$OUT" | head -4

echo
echo "built: $OUT  ($(du -h "$OUT" | cut -f1))"
