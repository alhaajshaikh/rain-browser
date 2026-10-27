#!/bin/bash
# Build only the isolated AVKit variant; SideStore supplies personal signing.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
BUILD_NUMBER="${1:?Usage: tools/avkit/build-app.sh NUMERIC_BUILD_VERSION}"
DIST_DIR="$REPO_DIR/dist"

if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    python3 "$SCRIPT_DIR/prepare-build.py" --build "$BUILD_NUMBER" --repository "$GITHUB_REPOSITORY"
else
    python3 "$SCRIPT_DIR/prepare-build.py" --build "$BUILD_NUMBER"
fi

xcodebuild archive \
    -scheme Reynard \
    -archivePath "$DIST_DIR/Rain.xcarchive" \
    -project "$DIST_DIR/avkit-build/browser/Reynard.xcodeproj" \
    -sdk iphoneos \
    -arch arm64 \
    -destination 'generic/platform=iOS' \
    -configuration Release \
    -xcconfig "$DIST_DIR/avkit-build/Rain.xcconfig" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    PROVISIONING_PROFILE_SPECIFIER= \
    2>&1 | tee "$DIST_DIR/Rain.xcodebuild.log"

# Match upstream's unsigned-archive treatment of the bundled Swift runtime.
CONCURRENCY_LIB="$DIST_DIR/Rain.xcarchive/Products/Applications/Reynard.app/Frameworks/libswift_Concurrency.dylib"
if [ -f "$CONCURRENCY_LIB" ]; then
    xcrun bitcode_strip "$CONCURRENCY_LIB" -r -o "$CONCURRENCY_LIB"
    /usr/bin/codesign --force --sign - "$CONCURRENCY_LIB"
fi

python3 "$SCRIPT_DIR/package-build.py"
