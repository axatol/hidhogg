#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
signing_identity=""
output_path="$repository_root/dist/Hidhogg.app"
scratch_path="/Volumes/Data/cache/hidhogg-swift-build"
disable_build_sandbox=0

fail() {
    printf 'build-app: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: scripts/build-app.sh --signing-identity IDENTITY [--output PATH] [--scratch-path PATH] [--disable-build-sandbox]

Builds and signs the arm64 macOS 26+ Hidhogg application bundle.
The signing identity is required; ad-hoc signing is not supported.
SwiftPM's subprocess sandbox stays enabled unless explicitly disabled.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --signing-identity)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || fail "--signing-identity requires an identity"
            signing_identity="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || fail "--output requires a path"
            output_path="$2"
            shift 2
            ;;
        --scratch-path)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || fail "--scratch-path requires a path"
            scratch_path="$2"
            shift 2
            ;;
        --disable-build-sandbox)
            disable_build_sandbox=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ -n "$signing_identity" ] || fail "--signing-identity is required"
[ "$signing_identity" != "-" ] || fail "ad-hoc signing is not supported"

case "$scratch_path" in
    /*) ;;
    *) fail "--scratch-path must be an absolute path under /Volumes/Data/cache or /Volumes/Data/tmp" ;;
esac

scratch_parent="$(cd "$(dirname "$scratch_path")" 2>/dev/null && pwd -P)" || fail "scratch path parent must already exist"
scratch_name="$(basename "$scratch_path")"
case "$scratch_name" in
    .|..|"") fail "scratch path must name a directory" ;;
esac
scratch_path="$scratch_parent/$scratch_name"

ensure_safe_scratch_path() {
    case "$1" in
        /Volumes/Data/cache/*|/Volumes/Data/tmp/*) ;;
        *) fail "scratch path must resolve under /Volumes/Data/cache or /Volumes/Data/tmp" ;;
    esac
}

if [ -d "$scratch_path" ]; then
    scratch_path="$(cd "$scratch_path" && pwd -P)"
fi
ensure_safe_scratch_path "$scratch_path"
mkdir -p "$scratch_path"
scratch_path="$(cd "$scratch_path" && pwd -P)"
ensure_safe_scratch_path "$scratch_path"

case "$output_path" in
    /*) ;;
    *) output_path="$repository_root/$output_path" ;;
esac
output_parent="$(dirname "$output_path")"
output_name="$(basename "$output_path")"
[ -n "$output_name" ] && [ "$output_name" != "." ] && [ "$output_name" != ".." ] || fail "output path must name a bundle"
case "$output_name" in
    *.app) ;;
    *) fail "output path must end in .app" ;;
esac
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output_path="$output_parent/$output_name"

stage_root=""
backup_path=""
destination_moved=0

cleanup() {
    status=$?
    trap - EXIT
    if [ "$destination_moved" -eq 1 ] && [ ! -e "$output_path" ] && [ -e "$backup_path" ]; then
        if mv "$backup_path" "$output_path"; then
            destination_moved=0
        else
            printf 'build-app: could not restore previous output from %s\n' "$backup_path" >&2
            status=1
        fi
    fi
    if [ -n "$stage_root" ] && [ -d "$stage_root" ]; then
        rm -rf "$stage_root"
    fi
    exit "$status"
}
trap cleanup EXIT

build_package() {
    if [ "$disable_build_sandbox" -eq 1 ]; then
        xcrun swift build \
            --package-path "$repository_root/app" \
            --scratch-path "$scratch_path" \
            --configuration release \
            --triple arm64-apple-macosx26.0 \
            --disable-sandbox "$@"
    else
        xcrun swift build \
            --package-path "$repository_root/app" \
            --scratch-path "$scratch_path" \
            --configuration release \
            --triple arm64-apple-macosx26.0 "$@"
    fi
}

printf 'Building Hidhogg for arm64 macOS 26...\n'
build_package

binary_directory="$(build_package --show-bin-path)"
binary_path="$binary_directory/Hidhogg"
[ -x "$binary_path" ] || fail "SwiftPM did not produce the Hidhogg executable"

stage_root="$(mktemp -d "$output_parent/.hidhogg-stage.XXXXXX")"
stage_app="$stage_root/Hidhogg.app"
icon_source="$repository_root/docs/product-redesign/logos/27-selected-serpent-padded.png"
iconset="$stage_root/Hidhogg.iconset"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$binary_path" "$stage_app/Contents/MacOS/Hidhogg"

mkdir "$iconset"
icon_sizes=(
    "16 16 icon_16x16.png"
    "32 32 icon_16x16@2x.png"
    "32 32 icon_32x32.png"
    "64 64 icon_32x32@2x.png"
    "128 128 icon_128x128.png"
    "256 256 icon_128x128@2x.png"
    "256 256 icon_256x256.png"
    "512 512 icon_256x256@2x.png"
    "512 512 icon_512x512.png"
    "1024 1024 icon_512x512@2x.png"
)
for icon_size in "${icon_sizes[@]}"; do
    read -r height width filename <<< "$icon_size"
    sips --resampleHeightWidth "$height" "$width" "$icon_source" --out "$iconset/$filename" >/dev/null
done
iconutil --convert icns --output "$stage_app/Contents/Resources/Hidhogg.icns" "$iconset"
rm -rf "$iconset"

cat > "$stage_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Hidhogg</string>
    <key>CFBundleIconFile</key>
    <string>Hidhogg</string>
    <key>CFBundleIdentifier</key>
    <string>com.hidhogg.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Hidhogg</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$stage_app/Contents/PkgInfo"

codesign --force --options runtime --timestamp=none --sign "$signing_identity" "$stage_app"
codesign --verify --strict --verbose=2 "$stage_app"

if [ -e "$output_path" ] || [ -L "$output_path" ]; then
    [ -d "$output_path" ] && [ ! -L "$output_path" ] || fail "existing output is not a bundle directory"
    backup_path="$output_parent/.$output_name.backup.$$"
    [ ! -e "$backup_path" ] && [ ! -L "$backup_path" ] || fail "backup path already exists: $backup_path"
    mv "$output_path" "$backup_path"
    destination_moved=1
fi

if mv "$stage_app" "$output_path"; then
    destination_moved=0
    if [ -n "$backup_path" ]; then
        rm -rf "$backup_path" || printf 'build-app: previous bundle retained at %s\n' "$backup_path" >&2
    fi
    printf 'Created signed app bundle: %s\n' "$output_path"
else
    fail "could not install the verified app bundle"
fi
