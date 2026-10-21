#!/bin/bash
set -e

echo "🔨 Building NetPulse for macOS (Universal Binary: arm64 + x86_64)..."

# Ensure bundle directories exist
mkdir -p NetPulse.app/Contents/MacOS
mkdir -p NetPulse.app/Contents/Resources

# Copy Info.plist and Icon
cp Info.plist NetPulse.app/Contents/Info.plist
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns NetPulse.app/Contents/Resources/AppIcon.icns
fi
if [ -f assets/logo.png ]; then
    cp assets/logo.png NetPulse.app/Contents/Resources/AppLogo.png
fi

# Compile both architectures
swiftc -parse-as-library -target arm64-apple-macos13.0 NetPulse.swift -o NetPulse_arm64
swiftc -parse-as-library -target x86_64-apple-macos13.0 NetPulse.swift -o NetPulse_x86_64

# Create universal binary
lipo -create -output NetPulse.app/Contents/MacOS/NetPulse NetPulse_arm64 NetPulse_x86_64
rm NetPulse_arm64 NetPulse_x86_64

# Ad-hoc code signing
codesign --force --deep --sign - NetPulse.app

# Create distribution archive
rm -f NetPulse.zip
zip -r -y NetPulse.zip NetPulse.app

echo "✅ Build complete! Binary: NetPulse.app, Archive: NetPulse.zip"
