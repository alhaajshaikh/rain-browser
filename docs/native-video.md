# Native video playback

The AVKit implementation lives in `NativeVideoPlaybackCoordinator.swift`. The
browser has small hooks for the page menu, fullscreen, navigation, tab selection,
and session closure. Gecko's privileged content actor selects and controls the
exact video element, including videos inside remote frames and shadow roots.

## Using it

- Start a video, then open the address bar's page menu and choose **Play Video in
  Native Player**. Compatible HTTP(S) streams open in Apple's player with PiP,
  AirPlay, native playback controls, and their current playback position.
  Use Apple's player's AirPlay control to choose a receiver. The fullscreen
  play-rectangle button opens the native player.
- Fullscreen video automatically attempts native playback. The page keeps playing
  until Apple's player is ready. Unsupported streams stay in the web player.
- Open the video fullscreen and choose **Picture in Picture** for browser-managed streams, including MSE streams
  commonly used by YouTube and Twitch. Fullscreen actions use a vertical strip
  in the video's side margin where space permits. All actions hide after three
  seconds, with no persistent handle. Tap the video to reveal them again; the
  website still receives that tap. VoiceOver keeps the actions available.
  The icons stay upright on rotation.
- Embedded videos have a PiP button at middle-right in portrait mode (including
  landscape videos viewed on a portrait phone). In a landscape window, a
  landscape video keeps its upper-right placement. It appears
  when a playable video is found, hides after three seconds, and reappears when
  the video is tapped. Starting PiP keeps the video embedded; it does not request
  document fullscreen. The address bar page menu remains another entry point.
  Scrolling immediately suppresses the inline controls, including momentum;
  they can resume only after a quiet interval and a fresh geometry response.
  Stale responses from before a scroll or rotation cannot reposition the UI.
  Pills retain a forty-point visible width and forty-four-point touch targets;
  a letterbox that is too narrow uses a padded overlay instead of shrinking it.
- If a video cannot open in the native player, the notice also offers
  **Screen Mirroring…** with Control Center instructions and **Hide Native
  Player Button**. iOS does not expose a public way for Rain to start system
  mirroring directly. Restore the button under **Settings → Browsing → Video**.
  Hiding it compacts fullscreen controls to the PiP button; the page menu remains
  available for native playback.
- A PiP video keeps its originating tab and compositor view alive when another
  tab is selected. The other tab remains available for browsing. Returning with
  the PiP restore control selects its original tab.
- After the user starts PiP, an autoplayed next video can continue in the same
  PiP window while Rain is foregrounded, backgrounded, or displaying another
  tab. The bridge follows only the original document/player after its video
  ends, including a same-element source change or one replacement video in that
  player. Loading gaps have a sixty-second grace period. Closing PiP disarms
  continuation; navigating or closing the source tab ends that session.
  Background loading gaps request one finite UIKit background task; playback
  readiness or PiP closure ends it. If iOS expires that task while the next
  video is still pending, the session ends rather than renewing the request.
- Closing the native player restores its position, playback rate and paused state
  to the same source element. Changing its source or navigating invalidates that
  handoff, preventing late commands from affecting a new video.

## Compatibility

Direct-stream playback uses AVPlayer, with native PiP and AirPlay when supported
by the device, receiver, and media format. Protected video and streams requiring
Gecko cookies or special request headers remain in the webpage. Browser cookies
are not copied to native network requests. A browser-managed `blob:`/MediaSource
stream cannot simply be reopened by AVPlayer or an AirPlay receiver.

Gecko-stream PiP uses AVKit's sample-buffer API on iOS 15 and later. An iOS-only
compositor patch makes ordinary SDR video eligible for native surfaces while
embedded. The selected video's viewport geometry and aspect ratio identify one
`AVSampleBufferDisplayLayer`; ambiguous matches are refused. This engine patch
requires rebuilding Gecko, rather than replacing JavaScript resources alone.
Gecko retains its own display timing. Finite videos expose their duration and
skip controls; live streams use their real DVR window when one is available.
Skip requests apply to the current position of the same video element. This
path does not provide AirPlay video streaming.
Control Center → Screen Mirroring can show the phone on a compatible receiver
for browser-managed streams; it is separate from native AirPlay video playback.
The controller remains available after a normal PiP stop so the same video can
restart without racing teardown. Explicit requests wait for pending cleanup
and briefly retry videos whose metadata is still loading.
Startup waits for a displayed frame on the same stable compositor surface and
rechecks that surface as fullscreen or rotation finishes. A confirmed AVKit
start failure gets one retry with a fresh controller. Readiness and start
acknowledgement have separate bounded timeouts. A PiP error's **Copy Details**
action includes renderer state and system error codes, without page addresses,
video addresses, titles, cookies, or target tokens.
A running controller can adopt a ready successor surface without closing its
PiP window. Source documents and tokens remain checked across this handoff.
Websites which replace sources without an ended transition, block autoplay,
or stop their player while backgrounded can prevent continuation. Full page
navigation starts a new document and is not automatically followed.
Rendering while backgrounded, returning from PiP after switching tabs, autoplay
across sites, live streams, and receiver compatibility require physical-device
verification.

## Keeping the feature while updating Reynard

Keep these changes committed on a feature branch. Merge upstream into that branch
and rebuild your custom app:

```sh
./tools/development/update-native-video.sh --check
./tools/development/update-native-video.sh --merge
```

The script refuses dirty worktrees and main/master branches. It uses a normal
Git merge so your native-video commits remain present; conflicts require review.
It does not change Git remotes. Its output explains the engine/build steps.
When Gecko's release changes, reapply and verify the two content-actor patches
against the newly pinned release before building. Do not reuse old engine
binaries with a different engine release.

Settings → About → **Check Official Releases** checks the official latest
release; it does not merge or install code. The separate AVKit preview explains
that an official IPA updates ordinary Reynard, and the same-ID custom build
explains that an official IPA replaces its video changes. iOS cannot pull, merge,
compile, and sign Swift/Gecko source in the installed
browser. A rebuilt custom IPA is needed until upstream accepts the feature.

To install a test build beside an existing Reynard, give the app and both
extensions distinct bundle identifiers and display names. Set a unique custom
URL scheme in the app's `CFBundleURLTypes` and the same `ReynardURLScheme` Info
key in both the app and OpenIn extension. This keeps the test share extension
from opening the existing browser. Keep the `Reynard Helper.appex` folder name:
Gecko reads that embedded extension's bundle identifier at runtime. The default
scheme remains `reynard` when the custom key is absent.

The side-by-side preview uses `NativeVideoAppIcon`, a separate asset catalog
icon set containing the user's supplied `IMG_1453.icns` artwork, extracted at
1024 pixels and composited over white for iOS. Select it with
`ASSETCATALOG_COMPILER_APPICON_NAME` when building that variant; the upstream
`AppIcon` set is preserved for regular builds.

The preview's display name is **Rain**, configured separately in
`browser/Configuration/NativeVideoPreview.json`. Its share action is **Open in
Rain**. Keep its existing `com.minh-ton.ReynardAVKit` app and extension identities
and `reynard-avkit` scheme when renaming it, so SideStore updates the installed
preview and its data rather than creating a new installation. Product and
executable names stay unchanged, including `Reynard Helper.appex`.

## Performance

Each discovery response shares one composed-tree traversal and query-local
geometry/style measurements. A later request always reads fresh DOM state;
there is no persistent cache that can hide newly added videos or shadow roots.
The optional synthetic host benchmark measures this work separately from
Gecko rendering and phone scrolling:

```sh
node tests/native-video-discovery-benchmark.mjs
```

Inline discovery uses one-shot timers outside UIKit's tracking run-loop mode.
Dragging, rotation and backgrounding stop optional discovery; momentum requires
a quiet interval and a fresh response before controls can resume. Visible
controls refresh every 0.6 seconds, hidden controls every two seconds. Empty
pages back off through 1.5, three and five seconds. Navigation, completed loads,
media-state changes, scrolling and control-reveal taps wake discovery sooner.
A video inserted silently into an otherwise idle page can therefore take up to
five seconds to acquire its inline button; the page menu queries immediately.
Active PiP and next-video continuation keep their separate playback polling.

Controls avoid unchanged frame/property assignments, repeated symbol creation,
per-update pan callbacks and replacement hide tasks with the same deadline.
These changes reduce work; host operation counts do not establish an iPhone
frame-rate improvement. Compare webpage scrolling on the phone separately.

## Validation

```sh
node --test tests/native-video-bridge.test.mjs
swiftc -parse-as-library browser/GeckoView/Session/NativeVideo.swift \
  tests/NativeVideoResponseChecks.swift -o /tmp/reynard-native-video-response-checks
/tmp/reynard-native-video-response-checks
swiftc -parse-as-library browser/GeckoView/Session/NativeVideo.swift \
  browser/GeckoView/Session/NativeVideoTimeline.swift \
  tests/NativeVideoTimelineChecks.swift -o /tmp/reynard-native-video-timeline-checks
/tmp/reynard-native-video-timeline-checks
swiftc -parse-as-library \
  browser/Reynard/Client/SessionManagement/Media/NativeVideoPiPLifecycle.swift \
  tests/NativeVideoPiPLifecycleChecks.swift -o /tmp/reynard-native-video-pip-lifecycle-checks
/tmp/reynard-native-video-pip-lifecycle-checks
swiftc browser/Reynard/Client/SessionManagement/Media/NativeVideoPiPStartPolicy.swift \
  tests/NativeVideoPiPStartPolicyChecks.swift -o /tmp/reynard-native-video-pip-start-checks
/tmp/reynard-native-video-pip-start-checks
swiftc browser/Reynard/Client/SessionManagement/Media/NativeVideoPiPDiagnostics.swift \
  tests/NativeVideoPiPDiagnosticsChecks.swift -o /tmp/reynard-native-video-pip-diagnostics-checks
/tmp/reynard-native-video-pip-diagnostics-checks
swiftc browser/Reynard/Client/SessionManagement/Media/NativeVideoFullscreenControlsLayout.swift \
  tests/NativeVideoFullscreenControlsLayoutTests.swift -o /tmp/reynard-fullscreen-controls-tests
/tmp/reynard-fullscreen-controls-tests
swiftc browser/Reynard/Client/SessionManagement/Media/NativeVideoFullscreenControlsVisibility.swift \
  tests/NativeVideoFullscreenControlsVisibilityChecks.swift -o /tmp/reynard-fullscreen-visibility-checks
/tmp/reynard-fullscreen-visibility-checks
swiftc browser/GeckoView/Session/NativeVideoSurfaceGeometry.swift \
  tests/NativeVideoSurfaceGeometryChecks.swift -o /tmp/reynard-video-surface-checks
/tmp/reynard-video-surface-checks
swiftc browser/Reynard/Client/SessionManagement/Media/NativeVideoPiPContinuation.swift \
  tests/NativeVideoPiPContinuationChecks.swift -o /tmp/reynard-video-continuation-checks
/tmp/reynard-video-continuation-checks
swiftc -parse-as-library browser/Reynard/Client/SessionManagement/Media/NativeVideoInlineControlsMotion.swift \
  tests/NativeVideoInlineControlsMotionChecks.swift -o /tmp/reynard-inline-motion-checks
/tmp/reynard-inline-motion-checks
swiftc -parse-as-library browser/Reynard/Client/SessionManagement/Media/NativeVideoInlineDiscoveryPolicy.swift \
  tests/NativeVideoInlineDiscoveryPolicyChecks.swift -o /tmp/reynard-inline-discovery-checks
/tmp/reynard-inline-discovery-checks
git diff --check
```

Device checks: MP4 and HLS; play/pause/rate/seek round-trip; failed native startup;
navigation and tab closure during startup and PiP; YouTube/Twitch MSE PiP;
background/foreground and lock-screen commands; an AirPlay receiver; private tabs;
iframes, live streams, DRM fallback, and multiple visible videos; inline PiP
without entering fullscreen; switching tabs while PiP opens; returning to a
source tab during cleanup; next-item autoplay in foreground/background; closing
PiP during a successor query and immediately restarting it.
Check portrait/landscape/square/ultrawide video controls, rotation during a drag,
scroll momentum, embedded-frame scrolling, a delayed geometry response, and
hiding/restoring the native-player button from its alert and Browsing settings.
