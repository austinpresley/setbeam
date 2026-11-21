#!/bin/bash
# Local build entry for the Setbeam Android TV receiver. No hosted CI.
# Usage: ./build.sh [gradle tasks...]   (default: unit tests, lint, debug and release APKs)
set -euo pipefail
cd "$(dirname "$0")"
: "${JAVA_HOME:=/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export JAVA_HOME ANDROID_HOME
if [ ! -x "$JAVA_HOME/bin/java" ]; then echo "JDK not found at $JAVA_HOME" >&2; exit 1; fi
if [ ! -d "$ANDROID_HOME/platforms" ]; then echo "Android SDK not found at $ANDROID_HOME" >&2; exit 1; fi
if [ "$#" -eq 0 ]; then set -- testDebugUnitTest lintDebug assembleDebug assembleRelease; fi
./gradlew --no-daemon "$@"
echo "Debug APK: $(pwd)/app/build/outputs/apk/debug/app-debug.apk"
