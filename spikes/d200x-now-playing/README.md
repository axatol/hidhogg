# D200X Now Playing layout spike

This standalone Swift renderer produces deterministic synthetic playback cards. It does not query a player, read user media, poll, launch an app, or connect to a device.

Run it with the macOS Swift 6 toolchain:

```sh
mkdir -p /Volumes/Data/tmp/d200x-now-playing
TMPDIR=/Volumes/Data/tmp swiftc -swift-version 6 -parse-as-library -module-cache-path /Volumes/Data/tmp/d200x-now-playing/module-cache spikes/d200x-now-playing/NowPlayingCardRenderer.swift -o /Volumes/Data/tmp/d200x-now-playing/renderer
/Volumes/Data/tmp/d200x-now-playing/renderer /Volumes/Data/tmp/d200x-now-playing
```

The output directory receives `playing.png`, `paused.png`, and `contact-sheet.png`. Each individual card is 458×196 pixels; the contact sheet places the playing and paused variants side by side. The artwork, title, artist, playback state, progress, and output mute state are fixed synthetic values in the source.

`PublicProviderSurfaceProbe.swift` is a compile-only check of public MediaPlayer and CoreAudio declarations. Its function bodies are type-checked but never executed, so it does not read app metadata or query an audio device.

Type-check that surface against the macOS 26.5 SDK without contacting any app or audio device:

```sh
TMPDIR=/Volumes/Data/tmp swiftc -swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macosx26.0 -typecheck -module-cache-path /Volumes/Data/tmp/d200x-now-playing/module-cache spikes/d200x-now-playing/PublicProviderSurfaceProbe.swift
```

The macOS 27-only `NowPlaying` session surface has a separate compile-only stand-in. It constructs no session at runtime and supplies no real media:

```sh
TMPDIR=/Volumes/Data/tmp swiftc -swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx27.0 -typecheck -module-cache-path /Volumes/Data/tmp/d200x-now-playing/module-cache spikes/d200x-now-playing/NowPlaying27SurfaceProbe.swift
```

See [the feasibility report](../../docs/d200x-now-playing-spike.md) for provider research, API boundaries, and production questions.
