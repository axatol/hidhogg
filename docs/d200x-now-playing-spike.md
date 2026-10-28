# D200X Now Playing feasibility spike

Checked 2026-10-28. The research used public Apple and Spotify documentation, the installed Music scripting definition, and the public macOS 26.5/27.0 SDKs. The host reports macOS 27.0.1 and Swift 6.4. No media item, account, audio route, app window, or running player was queried; no app was intentionally launched and no permission prompt was requested.

## Finding

A synthetic 458×196 card is straightforward to render. A supported universal macOS reader for arbitrary apps and browser tabs was not found. The public Apple Now Playing APIs are documented as publishing or handling commands for the app that owns the current session. Music has a usable app-specific scripting dictionary. A filesystem check at `/Applications/Spotify.app` and an `NSWorkspace` lookup for `com.spotify.client` did not resolve a Spotify app, so its local dictionary remains unverified. Those checks do not prove no unregistered copy exists. Spotify's public Web API is an account-authorized network integration, not a local universal provider.

Recommendation: if a production slice is approved, start with one explicitly selected local Music provider, keep output-device mute as a separate optional signal, and show unavailable data honestly. Add Spotify only after its local provider is verified and authorized. Treat browser-wide support as a separate provider project. Do not depend on MediaRemote without a separately approved research decision.

## Provider comparison

| Route | Evidence and coverage | Cost or limit | Assessment |
|---|---|---|---|
| Music via Apple Events | The installed Music definition exposes the current track, track name and artist, duration, player position/state, and artwork data. It also exposes a Music-app `mute` property. | Queries are per-app Apple Events. The Music `mute` property is Music playback output, not proof that the macOS default output device is muted. Automation access needs an explicit permission design. | Best first local provider if the owner accepts the Automation prompt and Music-only coverage. |
| Spotify via local Apple Events | Apple documents that each scriptable app defines its own scripting terminology. | The filesystem path check and bundle-ID lookup did not resolve an app; this does not prove that every possible unregistered copy is absent. Its dictionary and current macOS behavior remain unverified. | Add only after locating and inspecting the app's dictionary, then confirming owner permission. |
| Spotify Web API | Spotify's [current-playing endpoint](https://developer.spotify.com/documentation/web-api/reference/get-the-users-currently-playing-track) returns item, playing state, progress, and related metadata; it requires OAuth scope `user-read-currently-playing`. | Requires a Spotify account/token and network access. It covers Spotify only and does not report browser tabs or Apple Music. | A separate alternative if account/network use is explicitly accepted; outside this local spike. |
| Apple MediaPlayer / Now Playing | `MPNowPlayingInfoCenter` is documented for media the app plays. The installed SDK header says its default center holds information for the current application. Apple's [external-player event guidance](https://developer.apple.com/documentation/mediaplayer/handling-external-player-events-notifications) requires the receiving app to be the Now Playing app. The separate [Now Playing framework](https://developer.apple.com/documentation/nowplaying) is public in the macOS 27.0 SDK. | Apple's new framework is Beta and available starting macOS 27, not macOS 26. Its local `MediaSession` registers the calling app's model and exposes that app's primary-session state; the macOS interface marks `isSystemPrimary`, `requestToBecomeSystemPrimary()`, and `RemoteMediaSession` unavailable. No API to enumerate or read another app's session was found. | Useful only if Hidhogg publishes its own playback on macOS 27+. It does not provide a Music/Spotify/browser reader. |
| Private MediaRemote | No `MediaRemote.framework` path or public headers were present in the checked macOS 26.5/27.0 SDKs, and no Apple developer API documentation was found in this research. | An undocumented adapter has no public compatibility contract. If Mac App Store distribution applies, [Guideline 2.5.1](https://developer.apple.com/app-store/review/guidelines/) requires public APIs. This does not determine the rules for every other distribution route. | Not recommended for this slice. |

Apple's scripting guide explains that applications publish their own scripting dictionaries and that support varies by app ([Mac Automation Scripting Guide](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/HowMacScriptingWorks.html)). Local Music evidence came from extracting its definition with `sdef`; this did not send a script to Music or read a track. The extractor emitted a sandbox temp-cache warning but returned the dictionary entries with exit status 0.

The local definition check was:

```text
TMPDIR=/Volumes/Data/tmp /usr/bin/sdef /System/Applications/Music.app | rg -n -C 2 'property name="(name|mute|current track|player state|player position|duration|artist)"|class name="artwork"|property name="data"'
```

The current SDK inventory check was:

```text
rg --files /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/System/Library/Frameworks | rg '/(MediaRemote|NowPlaying)\.framework/'
```

It returned NowPlaying module files only under macOS 27.0 and no MediaRemote path. The macOS 27 Swift interface marks `MediaSession` as available from macOS 27 and marks system-primary and remote-session APIs unavailable on macOS. Its observable model, `MediaPlaybackSnapshot`, and artwork-provider closure are publisher inputs; the public interface exposes no system-wide session enumeration or other-app metadata getter.

The bounded Spotify checks were:

```text
stat /Applications/Spotify.app
exit 1: No such file or directory

TMPDIR=/Volumes/Data/tmp swift -e 'import AppKit; print(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")?.path ?? "not found")'
not found; exit 0
```

Apple describes `MPNowPlayingInfoCenter` as setting Now Playing information for media that the app plays ([MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)). The SDK declaration calls its default center the current application's center. The remote command APIs are likewise for an app handling playback events as the Now Playing app ([Handling external player events](https://developer.apple.com/documentation/mediaplayer/handling-external-player-events-notifications)). The new `NowPlaying` framework, available in the macOS 27 SDK, also publishes a caller-supplied `MediaSessionRepresentable` model and observes that model to update system UI. Its macOS interface supports the app's primary session but marks system-primary and remote-session APIs unavailable. Apple's documentation describes elapsed-time extrapolation and asynchronous artwork requests for that app-owned session ([publishing media sessions](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions), [playback snapshots](https://developer.apple.com/documentation/nowplaying/mediaplaybacksnapshot), [artwork and content](https://developer.apple.com/documentation/nowplaying/content-types-and-metadata)). Apple marks the framework Beta ([MediaSession](https://developer.apple.com/documentation/nowplaying/mediasession)). No Now Playing-specific privacy prompt or entitlement appeared in the checked publishing documentation or public interface; this API publishes the caller's model and does not grant access to another app's data. These sources support a narrow conclusion: no documented public universal reader was found; they do not prove that no undocumented mechanism exists.

Apple's public CoreAudio SDK defines `kAudioDevicePropertyMute` on audio-device controls ([CoreAudio mute property](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertymute)). A production reader should first check whether the chosen output device exposes the property and retain an unknown state if it does not. The compile-only probe in this spike checks only that the public declaration is available; it did not enumerate or query a device. The Music dictionary's app-level mute property and a CoreAudio output-device mute value must remain separate fields.

## Permission and update model

Sending Apple Events to another app requires an `NSAppleEventsUsageDescription` purpose string ([Apple documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)). The hardened-runtime Apple Events entitlement controls whether an app may prompt to send those events ([Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/security-entitlements/com.apple.security.automation.apple-events)). Production work would need to choose whether and when to request Music or Spotify Automation access. This spike changed no entitlement, signing setting, or permission state.

The provider boundary should return normalized snapshots rather than expose Music/Spotify scripting types to the tile:

```text
snapshot = { source, title?, artist?, artwork?, elapsed?, duration?, playbackState }
playbackState = playing | paused | stopped | unknown
availability = available | noItem | permissionRequired | notInstalled | failed
```

Keep output-device mute in a separate optional status value because its source and availability differ from track playback. `nil` means unknown; it must not become “unmuted.” Scripting dictionaries provide queryable properties, not a documented state-change stream for this UI, so a local adapter should be treated as request/response and refreshed only while the tile needs it. This is an inference from the exposed dictionary/API surface, not a claim that no app-specific notification exists. A future provider can advertise events if it documents them. By contrast, the macOS 27 Now Playing framework observes an app's own model and updates system UI; its `MediaPlaybackSnapshot` elapsed time and timestamp let the system extrapolate between updates. This is publisher-side behavior, not an event feed from other apps. Between Music snapshots, the Hidhogg UI can interpolate elapsed time from a monotonic anchor while state is playing; it need not query the player every display frame.

The first progress bar should be display-only. Do not present a seek affordance until a selected provider's seek command is implemented and verified. If duration or elapsed time is missing or invalid, hide the progress bar and time labels. Show a neutral empty state when there is no current item, show an explicit permission/provider-unavailable state when access fails, and use artwork/title fallbacks only for missing fields. Do not invent a track, progress value, playback state, or unmuted value.

## Synthetic render

[`NowPlayingCardRenderer.swift`](../spikes/d200x-now-playing/NowPlayingCardRenderer.swift) creates two fixed snapshots entirely in memory and writes `playing.png`, `paused.png`, and `contact-sheet.png` to the caller-provided directory. Each card is 458×196. The contact sheet is 942×196. Artwork, text, progress, playback status, and mute status are fake; the renderer has no timer, polling, app query, media library access, HID access, or platform effect.

The preview is at `/Volumes/Data/tmp/d200x-now-playing/contact-sheet.png`; individual files are `/Volumes/Data/tmp/d200x-now-playing/playing.png` and `/Volumes/Data/tmp/d200x-now-playing/paused.png`.

## Validation

Environment check:

```text
sw_vers --productVersion && swiftc --version
27.0.1; Apple Swift 6.4 (target arm64-apple-macosx27.0)
```

Successful renderer build and run:

```text
TMPDIR=/Volumes/Data/tmp swiftc -swift-version 6 -parse-as-library -module-cache-path /Volumes/Data/tmp/d200x-now-playing/module-cache spikes/d200x-now-playing/NowPlayingCardRenderer.swift -o /Volumes/Data/tmp/d200x-now-playing/renderer
exit 0

/Volumes/Data/tmp/d200x-now-playing/renderer /Volumes/Data/tmp/d200x-now-playing
Rendered synthetic cards at 458×196: /Volumes/Data/tmp/d200x-now-playing
exit 0
```

Compile-only public API check against the macOS 26.5 SDK, targeting macOS 26.0:

```text
TMPDIR=/Volumes/Data/tmp swiftc -swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macosx26.0 -typecheck -module-cache-path /Volumes/Data/tmp/d200x-now-playing/module-cache spikes/d200x-now-playing/PublicProviderSurfaceProbe.swift
exit 0
```

Compile-only Now Playing session stand-in against macOS 27.0, targeting macOS 27.0:

```text
TMPDIR=/Volumes/Data/tmp swiftc -swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 -typecheck -module-cache-path /Volumes/Data/tmp/d200x-now-playing/module-cache spikes/d200x-now-playing/NowPlaying27SurfaceProbe.swift
exit 0
```

Image dimensions were checked with:

```text
sips --getProperty pixelWidth --getProperty pixelHeight /Volumes/Data/tmp/d200x-now-playing/playing.png /Volumes/Data/tmp/d200x-now-playing/paused.png /Volumes/Data/tmp/d200x-now-playing/contact-sheet.png
playing.png: 458×196; paused.png: 458×196; contact-sheet.png: 942×196
```

The first renderer run used atomic file writing and failed with `NSPOSIXErrorDomain Code=1`; direct writes to the designated temporary output directory succeeded. No package tests or production build were run.

## Production follow-up

Use the selected macOS output device's mute state, matching HidHogg's existing volume actions. A player's own mute flag is a separate concept and must not substitute for unavailable output-device state.

The recommended first provider is an opt-in Music adapter because its installed scripting definition was verified. A production adapter would need an explicit permission purpose, hardened-runtime entitlement and a user-triggered Automation consent flow; this spike neither adds those permissions nor queries Music. Spotify and browser coverage need separately verified adapters. Provider breadth remains a product choice before that production work; the current spike is complete without selecting or contacting a live player.

Undocumented universal-reader APIs are not selected for this implementation. A future private-API investigation needs its own compatibility/distribution decision rather than being silently bundled into the display feature.
