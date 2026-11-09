#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="build/Milky Way Studio.app"
mkdir -p build/cache

echo "==> Cleaning bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Milky Way Studio"
swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 -sdk "$SDK" \
  -module-cache-path build/cache \
  Sources/App.swift \
  Sources/Palette.swift \
  Sources/AstroModel.swift \
  Sources/ShaderTypes.swift \
  Sources/GalaxyEngine.swift \
  Sources/ImageExporter.swift \
  Sources/GalaxyRenderer.swift \
  Sources/StudioState.swift \
  Sources/MetalViewport.swift \
  Sources/ContentView.swift \
  -o "$APP/Contents/MacOS/MilkyWayStudio" \
  -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit \
  -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers -framework QuartzCore

echo "==> Compiling CLI renderer"
swiftc -O -swift-version 5 -module-cache-path build/cache \
  Sources/AstroModel.swift Sources/ShaderTypes.swift Sources/GalaxyEngine.swift Sources/ImageExporter.swift Sources/CLI/main.swift \
  -o build/galaxycli \
  -framework Metal -framework Foundation -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers

echo "==> Bundling resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Sources/Shaders.metal "$APP/Contents/Resources/Shaders.metal"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built: $APP"
echo "Run:   open \"$APP\""
