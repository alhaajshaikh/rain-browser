#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reynard-avkit-checks.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
cd "$REPO_DIR"

python3 -B tools/avkit/build-validation-checks.py
python3 -B -m unittest discover -s tests -p 'test_avkit_source.py'
python3 -B -m unittest discover -s tests -p 'test_avkit_upstream.py'
python3 -B -m unittest discover -s tests -p 'test_avkit_build_plan.py'
python3 -B -m unittest discover -s tests -p 'test_avkit_publication.py'
node --test tests/native-video-bridge.test.mjs
compile_check() {
    local name="$1"
    shift
    swiftc -module-cache-path "$CHECK_DIR/module-cache" -parse-as-library "$@" -o "$CHECK_DIR/$name"
    "$CHECK_DIR/$name"
}
compile_check response browser/GeckoView/Session/NativeVideo.swift tests/NativeVideoResponseChecks.swift
compile_check timeline browser/GeckoView/Session/NativeVideo.swift browser/GeckoView/Session/NativeVideoTimeline.swift tests/NativeVideoTimelineChecks.swift
MEDIA_DIR=browser/Reynard/Client/SessionManagement/Media
compile_check lifecycle "$MEDIA_DIR/NativeVideoPiPLifecycle.swift" tests/NativeVideoPiPLifecycleChecks.swift
compile_check startup "$MEDIA_DIR/NativeVideoPiPStartPolicy.swift" tests/NativeVideoPiPStartPolicyChecks.swift
compile_check diagnostics "$MEDIA_DIR/NativeVideoPiPDiagnostics.swift" tests/NativeVideoPiPDiagnosticsChecks.swift
compile_check layout "$MEDIA_DIR/NativeVideoFullscreenControlsLayout.swift" tests/NativeVideoFullscreenControlsLayoutTests.swift
compile_check visibility "$MEDIA_DIR/NativeVideoFullscreenControlsVisibility.swift" tests/NativeVideoFullscreenControlsVisibilityChecks.swift
compile_check surface browser/GeckoView/Session/NativeVideoSurfaceGeometry.swift tests/NativeVideoSurfaceGeometryChecks.swift
compile_check continuation "$MEDIA_DIR/NativeVideoPiPContinuation.swift" tests/NativeVideoPiPContinuationChecks.swift
compile_check motion "$MEDIA_DIR/NativeVideoInlineControlsMotion.swift" tests/NativeVideoInlineControlsMotionChecks.swift
compile_check discovery "$MEDIA_DIR/NativeVideoInlineDiscoveryPolicy.swift" tests/NativeVideoInlineDiscoveryPolicyChecks.swift
git diff --check
