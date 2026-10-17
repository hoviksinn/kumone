#!/bin/bash
# Builds Kumone with SwiftPM and wraps the product into a .app bundle.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

CONF="${1:-debug}"
APP_NAME="Kumone"
BUNDLE_ID="com.hoviksinn.kumone.test"
DISPLAY_NAME="Kumone Test"
# This fork only packages isolated test builds; upstream updates stay disabled.
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "error: build on Apple Silicon macOS 26+ with Xcode (or use GitHub Actions)." >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=26.0
TRIPLE="arm64-apple-macosx26.0"
# Version resolution: environment > version.env > defaults.
ENV_MARKETING_VERSION="${MARKETING_VERSION:-}"
ENV_BUILD_NUMBER="${BUILD_NUMBER:-}"
MARKETING_VERSION="0.1.0"
BUILD_NUMBER="1"
[ -f "$ROOT/version.env" ] && source "$ROOT/version.env"
[ -n "$ENV_MARKETING_VERSION" ] && MARKETING_VERSION="$ENV_MARKETING_VERSION"
[ -n "$ENV_BUILD_NUMBER" ] && BUILD_NUMBER="$ENV_BUILD_NUMBER"

BUILD_DIR="$ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# One native arm64 build. SwiftPM supplies resources from this same tree.
swift build -c "$CONF" --triple "$TRIPLE" --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONF" --triple "$TRIPLE" --show-bin-path)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Embed Sparkle.framework (SwiftPM binary artifact) into Contents/Frameworks.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -n1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "ERROR: Sparkle.framework not found under .build/artifacts" >&2
  exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -a "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"

# MLX's Metal kernels, for AutoMix stem transitions. MLX loads `mlx.metallib`
# from beside the running binary first, so the app always gets one there.
# Sources, most specific first:
#   1. $BIN_PATH/mlx.metallib — placed beside this very configuration's binary
#      by Scripts/fetch-mlx-metallib.sh (Command Line Tools builds).
#   2. The kernels SwiftPM compiled in this build — with Xcode (and its Metal
#      Toolchain) mlx-swift's sources become
#      $BIN_PATH/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib and
#      no file named mlx.metallib exists. Built from the pinned sources by
#      this same invocation, so it cannot be stale.
# Without any of them the app would never pre-render stem hand-overs
# (StemKit.ResidentStemSeparator.isRunnable says no).
CMLX_METALLIB="$BIN_PATH/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ -f "$BIN_PATH/mlx.metallib" ]; then
  METALLIB="$BIN_PATH/mlx.metallib"
elif [ -f "$CMLX_METALLIB" ]; then
  METALLIB="$CMLX_METALLIB"
else
  METALLIB=""
fi
if [ -z "$METALLIB" ] && [ "${FETCH_MLX_METALLIB:-0}" = "1" ]; then
  # CI: fetch the pinned, sha-verified kernels rather than compile them.
  "$SCRIPT_DIR/fetch-mlx-metallib.sh" "$BIN_PATH"
  METALLIB="$BIN_PATH/mlx.metallib"
fi
if [ -n "$METALLIB" ]; then
  echo "mlx.metallib <- $METALLIB"
  cp "$METALLIB" "$APP_BUNDLE/Contents/MacOS/mlx.metallib"
else
  # Shipping without the kernels silently disables every stem hand-over and
  # is indistinguishable from a planner bug in the field (2026-08-31: a day
  # of "everything falls to stagedEQ" traced back to exactly this). Fail
  # loudly instead; a clean of .build eats the metallib, and the fix is one
  # command.
  echo "error: no mlx.metallib under .build and no compiled Cmlx kernels at" >&2
  echo "       $CMLX_METALLIB —" >&2
  echo "       the app would ship with stem separation disabled. Run" >&2
  echo "       Scripts/fetch-mlx-metallib.sh (after 'swift build -c release" >&2
  echo "       --product Kumone') first, or with Xcode install the Metal" >&2
  echo "       Toolchain (xcodebuild -downloadComponent MetalToolchain)." >&2
  exit 1
fi

# Localization tables → Bundle.main
cp "$ROOT/Sources/Kumone/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/"
for lproj in "$ROOT"/Sources/Kumone/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

# SwiftPM resource bundles (if any). mlx-swift_Cmlx.bundle only carries the
# kernels already copied to Contents/MacOS/mlx.metallib above (~100 MB), and
# MLX finds the colocated copy first, so it is left out.
find "$BIN_PATH" -maxdepth 1 -name '*.bundle' -not -name '*Tests*' \
  -not -name 'mlx-swift_Cmlx.bundle' -print0 |
  while IFS= read -r -d '' bundle; do
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
  done

# App icon: compile the Icon Composer bundle into Assets.car and keep the
# source bundle alongside for Liquid Glass light/dark rendering on macOS 26.
ICON_SOURCE="$ROOT/AppIcon.icon"
if [ -d "$ICON_SOURCE" ]; then
  cp -R "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icon"
  xcrun actool "$ICON_SOURCE" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --notices --warnings --errors \
    --output-partial-info-plist "$BUILD_DIR/icon-partial.plist" \
    --app-icon AppIcon \
    --development-region zh-Hans \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx >/dev/null
  if [ ! -f "$APP_BUNDLE/Contents/Resources/Assets.car" ]; then
    echo "ERROR: actool did not produce Assets.car" >&2
    exit 1
  fi
fi

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconName</key><string>AppIcon</string>
        </dict>
    </dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 missuo</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>KumoneGitCommit</key><string>$GIT_COMMIT</string>
    <key>KumoneDisableUpdates</key><true/>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>
</dict>
</plist>
PLIST

# The prebuilt Sparkle dependency contains helper binaries. Keep only arm64
# slices in the test bundle, then apply fresh ad-hoc signatures from inside out.
FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    if [ "$(lipo -archs "$binary")" != "arm64" ]; then
      lipo "$binary" -thin arm64 -output "$binary.arm64"
      mv "$binary.arm64" "$binary"
    fi
  fi
done < <(find "$FRAMEWORK" -type f -print0)

xattr -cr "$APP_BUNDLE"
for component in \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK" \
  "$APP_BUNDLE/Contents/MacOS/mlx.metallib" \
  "$APP_BUNDLE"; do
  codesign --force --sign - "$component"
done
codesign --verify --deep --strict "$APP_BUNDLE"

echo "Built $APP_BUNDLE ($CONF, $GIT_COMMIT)"
